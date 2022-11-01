module bridge::token_bridge {
    use std::error;
    use std::string;
    use std::vector;
    use std::signer::{address_of};

    use aptos_std::table::{Self, Table};
    use aptos_std::event::{Self, EventHandle};
    use aptos_std::type_info::{Self, TypeInfo};
    use aptos_std::from_bcs::to_address;
    use aptos_std::math64;

    use aptos_token::token::{Self, Token, TokenId};
    use aptos_framework::account;

    use layerzero_common::serde;
    use layerzero_common::utils::{vector_slice, assert_u16, assert_signer, assert_length};
    use layerzero::endpoint::{Self, UaCapability};
    use layerzero::lzapp;
    use layerzero::remote;
    use zro::zro::ZRO;

    const EBRIDGE_UNREGISTERED_TOKEN: u64 = 0x00;
    const EBRIDGE_TOKEN_ALREADY_EXISTS: u64 = 0x01;
    const EBRIDGE_REMOTE_TOKEN_NOT_FOUND: u64 = 0x02;
    const EBRIDGE_INVALID_TOKEN_TYPE: u64 = 0x03;
    const EBRIDGE_CLAIMABLE_TOKEN_NOT_FOUND: u64 = 0x04;
    const EBRIDGE_INVALID_TOKEN_DECIMALS: u64 = 0x05;
    const EBRIDGE_TOKEN_NOT_UNWRAPPABLE: u64 = 0x06;
    const EBRIDGE_INSUFFICIENT_LIQUIDITY: u64 = 0x07;
    const EBRIDGE_INVALID_ADDRESS: u64 = 0x08;
    const EBRIDGE_INVALID_SIGNER: u64 = 0x09;
    const EBRIDGE_INVALID_PACKET_TYPE: u64 = 0x0a;
    const EBRIDGE_PAUSED: u64 = 0x0b;
    const EBRIDGE_SENDING_AMOUNT_TOO_FEW: u64 = 0x0c;
    const EBRIDGE_INVALID_ADAPTER_PARAMS: u64 = 0x0d;

    // paceket type, in line with EVM
    const PRECEIVE: u8 = 0;
    const PSEND: u8 = 1;

    const SEND_PAYLOAD_SIZE: u64 = 74;

    // layerzero user application generic type for this app
    struct BridgeUA {}

    struct Path has copy, drop {
        remote_chain_id: u64,
        remote_token_addr: vector<u8>,
    }

    struct CoinTypeStore has key {
        type_lookup: Table<Path, TypeInfo>,
        types: vector<TypeInfo>,
    }

    struct LzCapability has key {
        cap: UaCapability<BridgeUA>
    }

    struct Config has key {
        paused_global: bool,
        paused_tokens: Table<TypeInfo, bool>, // token type -> paused
        custom_adapter_params: bool,
    }

    struct RemoteCoin has store, drop {
        remote_address: vector<u8>,
        // in shared decimals
        tvl_sd: u64,
        // whether the token can be unwrapped into native token on remote chain, like WETH -> ETH on ethereum, WBNB -> BNB on BSC
        unwrappable: bool,
    }

    struct CoinStore<phantom CoinType> has key {
        ld2sd_rate: u64,
        // chainId -> remote token
        remote_tokens: Table<u64, RemoteCoin>,
        // chain id of remote tokens
        remote_chains: vector<u64>,
        claimable_amt_ld: Table<address, u64>,
        // token caps
        mint_cap: MintCapability<CoinType>,
        burn_cap: BurnCapability<CoinType>,
        freeze_cap: FreezeCapability<CoinType>,
    }

    struct EventStore has key {
        send_events: EventHandle<SendEvent>,
        receive_events: EventHandle<ReceiveEvent>,
        claim_events: EventHandle<ClaimEvent>,
    }

    struct SendEvent has drop, store {
        token_type: TypeInfo,
        dst_chain_id: u64,
        dst_receiver: vector<u8>,
        amount_ld: u64,
        unwrap: bool,
    }

    struct ReceiveEvent has drop, store {
        token_type: TypeInfo,
        src_chain_id: u64,
        receiver: address,
        amount_ld: u64,
        stashed: bool,
    }

    struct ClaimEvent has drop, store {
        token_type: TypeInfo,
        receiver: address,
        amount_ld: u64,
    }

    fun init_module(account: &signer) {
        let cap = endpoint::register_ua<BridgeUA>(account);
        lzapp::init(account, cap);
        remote::init(account);

        move_to(account, LzCapability { cap });

        move_to(account, Config {
            paused_global: false,
            paused_tokens: table::new(),
            custom_adapter_params: false,
        });

        move_to(account, CoinTypeStore {
            type_lookup: table::new(),
            types: vector::empty(),
        });

        move_to(account, EventStore {
            send_events: account::new_event_handle<SendEvent>(account),
            receive_events: account::new_event_handle<ReceiveEvent>(account),
            claim_events: account::new_event_handle<ClaimEvent>(account),
        });
    }

    // one registered CoinType can have multiple remote tokens, e.g. ETH-USDC and AVAX-USDC
    public entry fun set_remote_token<CoinType>(
        account: &signer,
        remote_chain_id: u64,
        remote_token_addr: vector<u8>,
        unwrappable: bool,
    ) acquires CoinStore, CoinTypeStore {
        assert_signer(account, @bridge);
        assert_u16(remote_chain_id);
        assert_length(&remote_token_addr, 32);
        assert_registered_token<CoinType>();

        let token_store = borrow_global_mut<CoinStore<CoinType>>(@bridge);
        assert!(!table::contains(&token_store.remote_tokens, remote_chain_id), error::invalid_argument(EBRIDGE_TOKEN_ALREADY_EXISTS));

        let remote_token = RemoteCoin {
            remote_address: remote_token_addr,
            tvl_sd: 0,
            unwrappable,
        };
        table::add(&mut token_store.remote_tokens, remote_chain_id, remote_token);
        vector::push_back(&mut token_store.remote_chains, remote_chain_id);

        let type_store = borrow_global_mut<CoinTypeStore>(@bridge);
        table::add(&mut type_store.type_lookup, Path { remote_chain_id, remote_token_addr }, type_info::type_of<CoinType>());
    }

    public entry fun set_global_pause(account: &signer, paused: bool) acquires Config {
        assert_signer(account, @bridge);

        let config = borrow_global_mut<Config>(@bridge);
        config.paused_global = paused;
    }

    public entry fun set_pause<CoinType>(account: &signer, paused: bool) acquires Config {
        assert_signer(account, @bridge);
        assert_registered_token<CoinType>();

        let config = borrow_global_mut<Config>(@bridge);
        table::upsert(&mut config.paused_tokens, type_info::type_of<CoinType>(), paused);
    }

    public entry fun enable_custom_adapter_params(account: &signer, enabled: bool) acquires Config {
        assert_signer(account, @bridge);

        let config = borrow_global_mut<Config>(@bridge);
        config.custom_adapter_params = enabled;
    }

    public fun get_token_capabilities<CoinType>(account: &signer): (MintCapability<CoinType>, BurnCapability<CoinType>, FreezeCapability<CoinType>) acquires CoinStore {
        assert_signer(account, @bridge);
        assert_registered_token<CoinType>();

        let token_store = borrow_global<CoinStore<CoinType>>(@bridge);
        (token_store.mint_cap, token_store.burn_cap, token_store.freeze_cap)
    }

    //
    // token transfer functions
    //
    public fun send_token<CoinType>(
        token: Coin<CoinType>,
        dst_chain_id: u64,
        dst_receiver: vector<u8>,
        fee: Coin<AptosCoin>,
        unwrap: bool,
        adapter_params: vector<u8>,
        msglib_params: vector<u8>,
    ): Coin<AptosCoin> acquires CoinStore, EventStore, Config, LzCapability {
        let (native_refund, zro_refund) = send_token_with_zro(token, dst_chain_id, dst_receiver, fee, token::zero<ZRO>(), unwrap, adapter_params, msglib_params);
        token::destroy_zero(zro_refund);
        native_refund
    }

    public fun send_token_with_zro<CoinType>(
        token: Coin<CoinType>,
        dst_chain_id: u64,
        dst_receiver: vector<u8>,
        native_fee: Coin<AptosCoin>,
        zro_fee: Coin<ZRO>,
        unwrap: bool,
        adapter_params: vector<u8>,
        msglib_params: vector<u8>,
    ): (Coin<AptosCoin>, Coin<ZRO>) acquires CoinStore, EventStore, Config, LzCapability {
        let amount_ld = token::value(&token);
        let send_amount_ld = remove_dust_ld<CoinType>(token::value(&token));
        if (amount_ld > send_amount_ld) {
            // remove the dust and deposit into the bridge account
            let dust = token::extract(&mut token, amount_ld - send_amount_ld);
            token::deposit(@bridge, dust);
        };
        let (native_refund, zro_refund) = send_token_internal(token, dst_chain_id, dst_receiver, native_fee, zro_fee, unwrap, adapter_params, msglib_params);

        (native_refund, zro_refund)
    }

    public entry fun send_token_from<CoinType>(
        sender: &signer,
        dst_chain_id: u64,
        dst_receiver: vector<u8>,
        amount_ld: u64,
        native_fee: u64,
        zro_fee: u64,
        unwrap: bool,
        adapter_params: vector<u8>,
        msglib_params: vector<u8>,
    ) acquires CoinStore, EventStore, Config, LzCapability {
        let send_amt_ld = remove_dust_ld<CoinType>(amount_ld);
        let token = token::withdraw<CoinType>(sender, send_amt_ld);
        let native_fee = withdraw_token_if_needed<AptosCoin>(sender, native_fee);
        let zro_fee = withdraw_token_if_needed<ZRO>(sender, zro_fee);

        let (native_refund, zro_refund) = send_token_internal(token, dst_chain_id, dst_receiver, native_fee, zro_fee, unwrap, adapter_params, msglib_params);

        // deposit back to sender
        let sender_addr = address_of(sender);
        deposit_token_if_needed(sender_addr, native_refund);
        deposit_token_if_needed(sender_addr, zro_refund);
    }

    fun send_token_internal<CoinType>(
        token: Coin<CoinType>,
        dst_chain_id: u64,
        dst_receiver: vector<u8>,
        native_fee: Coin<AptosCoin>,
        zro_fee: Coin<ZRO>,
        unwrap: bool,
        adapter_params: vector<u8>,
        msglib_params: vector<u8>,
    ): (Coin<AptosCoin>, Coin<ZRO>) acquires CoinStore, EventStore, Config, LzCapability {
        assert_registered_token<CoinType>();
        assert_unpaused<CoinType>();
        assert_u16(dst_chain_id);
        assert_length(&dst_receiver, 32);

        // assert that the remote token is configured
        let token_store = borrow_global_mut<CoinStore<CoinType>>(@bridge);
        assert!(table::contains(&token_store.remote_tokens, dst_chain_id), error::not_found(EBRIDGE_REMOTE_TOKEN_NOT_FOUND));

        // the dust value of the token has been removed
        let amount_ld = token::value(&token);
        let amount_sd = ld2sd(amount_ld, token_store.ld2sd_rate);
        assert!(amount_sd > 0, error::invalid_argument(EBRIDGE_SENDING_AMOUNT_TOO_FEW));

        // try to insert into the limiter. abort if overflowed
        limiter::try_insert<CoinType>(amount_sd);

        // assert remote chain has enough liquidity
        let remote_token = table::borrow_mut(&mut token_store.remote_tokens, dst_chain_id);
        assert!(remote_token.tvl_sd >= amount_sd, error::invalid_argument(EBRIDGE_INSUFFICIENT_LIQUIDITY));
        remote_token.tvl_sd = remote_token.tvl_sd - amount_sd;

        // burn the token
        token::burn(token, &token_store.burn_cap);

        // check gas limit with adapter params
        check_adapter_params(dst_chain_id, &adapter_params);

        // build payload
        if (unwrap) {
            assert!(remote_token.unwrappable, error::invalid_argument(EBRIDGE_TOKEN_NOT_UNWRAPPABLE));
        };
        let payload = encode_send_payload(remote_token.remote_address, dst_receiver, amount_sd, unwrap);

        // send lz msg to remote bridge
        let lz_cap = borrow_global<LzCapability>(@bridge);
        let dst_address = remote::get(@bridge, dst_chain_id);
        let (_, native_refund, zro_refund) = lzapp::send_with_zro<BridgeUA>(
            dst_chain_id,
            dst_address,
            payload,
            native_fee,
            zro_fee,
            adapter_params,
            msglib_params,
            &lz_cap.cap
        );

        // emit event
        let event_store = borrow_global_mut<EventStore>(@bridge);
        event::emit_event<SendEvent>(
            &mut event_store.send_events,
            SendEvent {
                token_type: type_info::type_of<CoinType>(),
                dst_chain_id,
                dst_receiver,
                amount_ld,
                unwrap,
            },
        );

        (native_refund, zro_refund)
    }

    public entry fun lz_receive<CoinType>(src_chain_id: u64, src_address: vector<u8>, payload: vector<u8>) acquires CoinStore, EventStore, Config, LzCapability {
        assert_registered_token<CoinType>();
        assert_unpaused<CoinType>();
        assert_u16(src_chain_id);

        // assert the payload is valid
        remote::assert_remote(@bridge, src_chain_id, src_address);
        let lz_cap = borrow_global<LzCapability>(@bridge);
        endpoint::lz_receive<BridgeUA>(src_chain_id, src_address, payload, &lz_cap.cap);

        // decode payload and get token amount
        let (remote_token_addr, receiver_bytes, amount_sd) = decode_receive_payload(&payload);

        // assert remote_token_addr
        let token_store = borrow_global_mut<CoinStore<CoinType>>(@bridge);
        assert!(table::contains(&token_store.remote_tokens, src_chain_id), error::not_found(EBRIDGE_REMOTE_TOKEN_NOT_FOUND));
        let remote_token = table::borrow_mut(&mut token_store.remote_tokens, src_chain_id);
        assert!(remote_token_addr == remote_token.remote_address, error::invalid_argument(EBRIDGE_INVALID_TOKEN_TYPE));

        // add to tvl
        remote_token.tvl_sd = remote_token.tvl_sd + amount_sd;

        let amount_ld = sd2ld(amount_sd, token_store.ld2sd_rate);

        // stash if the receiver has not yet registered to receive the token
        let receiver = to_address(receiver_bytes);
        let stashed = !token::is_account_registered<CoinType>(receiver);
        if (stashed) {
            let claimable_ld = table::borrow_mut_with_default(&mut token_store.claimable_amt_ld, receiver, 0);
            *claimable_ld = *claimable_ld + amount_ld;
        } else {
            let tokens_minted = token::mint(amount_ld, &token_store.mint_cap);
            token::deposit(receiver, tokens_minted);
        };

        // emit event
        let event_store = borrow_global_mut<EventStore>(@bridge);
        event::emit_event(
            &mut event_store.receive_events,
            ReceiveEvent {
                token_type: type_info::type_of<CoinType>(),
                src_chain_id,
                receiver,
                amount_ld,
                stashed,
            }
        );
    }

    public entry fun claim_token<CoinType>(receiver: &signer) acquires CoinStore, EventStore, Config {
        assert_registered_token<CoinType>();
        assert_unpaused<CoinType>();

        // register the user if needed
        let receiver_addr = address_of(receiver);
        if (!token::is_account_registered<CoinType>(receiver_addr)) {
            token::register<CoinType>(receiver);
        };

        // assert the receiver has receivable and it is more than 0
        let token_store = borrow_global_mut<CoinStore<CoinType>>(@bridge);
        assert!(table::contains(&token_store.claimable_amt_ld, receiver_addr), error::not_found(EBRIDGE_CLAIMABLE_TOKEN_NOT_FOUND));
        let claimable_ld = table::remove(&mut token_store.claimable_amt_ld, receiver_addr);
        assert!(claimable_ld > 0, error::not_found(EBRIDGE_CLAIMABLE_TOKEN_NOT_FOUND));

        let tokens_minted = token::mint(claimable_ld, &token_store.mint_cap);
        token::deposit(receiver_addr, tokens_minted);

        // emit event
        let event_store = borrow_global_mut<EventStore>(@bridge);
        event::emit_event(
            &mut event_store.claim_events,
            ClaimEvent {
                token_type: type_info::type_of<CoinType>(),
                receiver: receiver_addr,
                amount_ld: claimable_ld,
            }
        );
    }

    //
    // public view functions
    //
    public fun lz_receive_types(src_chain_id: u64, _src_address: vector<u8>, payload: vector<u8>): vector<TypeInfo> acquires CoinTypeStore {
        let (remote_token_addr, _receiver, _amount) = decode_receive_payload(&payload);
        let path = Path { remote_chain_id: src_chain_id, remote_token_addr };

        let type_store = borrow_global<CoinTypeStore>(@bridge);
        let token_type_info = table::borrow(&type_store.type_lookup, path);

        vector::singleton<TypeInfo>(*token_type_info)
    }

    public fun has_token_registered<CoinType>(): bool {
        exists<CoinStore<CoinType>>(@bridge)
    }

    public fun quote_fee(dst_chain_id: u64, pay_in_zro: bool, adapter_params: vector<u8>, msglib_params: vector<u8>): (u64, u64) {
        endpoint::quote_fee(@bridge, dst_chain_id, SEND_PAYLOAD_SIZE, pay_in_zro, adapter_params, msglib_params)
    }

    public fun remove_dust_ld<CoinType>(amount_ld: u64): u64 acquires CoinStore {
        let token_store = borrow_global<CoinStore<CoinType>>(@bridge);
        amount_ld / token_store.ld2sd_rate * token_store.ld2sd_rate
    }

    //
    // internal functions
    //
    fun withdraw_token_if_needed<CoinType>(account: &signer, amount_ld: u64): Coin<CoinType> {
        if (amount_ld > 0) {
            token::withdraw<CoinType>(account, amount_ld)
        } else {
            token::zero<CoinType>()
        }
    }

    fun deposit_token_if_needed<CoinType>(account: address, token: Coin<CoinType>) {
        if (token::value(&token) > 0) {
            token::deposit(account, token);
        } else {
            token::destroy_zero(token);
        }
    }

    // ld = local decimal. sd = shared decimal among all chains
    fun ld2sd(amount_ld: u64, ld2sd_rate: u64): u64 {
        amount_ld / ld2sd_rate
    }

    fun sd2ld(amount_sd: u64, ld2sd_rate: u64): u64 {
        amount_sd * ld2sd_rate
    }

    // encode payload: packet type(1) + remote token(32) + receiver(32) + amount(8) + unwarp flag(1)
    fun encode_send_payload(dst_token_addr: vector<u8>, dst_receiver: vector<u8>, amount_sd: u64, unwrap: bool): vector<u8> {
        assert_length(&dst_token_addr, 32);
        assert_length(&dst_receiver, 32);

        let payload = vector::empty<u8>();
        serde::serialize_u8(&mut payload, PSEND);
        serde::serialize_vector(&mut payload, dst_token_addr);
        serde::serialize_vector(&mut payload, dst_receiver);
        serde::serialize_u64(&mut payload, amount_sd);
        let unwrap = if (unwrap) { 1 } else { 0 };
        serde::serialize_u8(&mut payload, unwrap);
        payload
    }

    // decode payload: packet type(1) + remote token(32) + receiver(32) + amount(8)
    fun decode_receive_payload(payload: &vector<u8>): (vector<u8>, vector<u8>, u64) {
        assert_length(payload, 73);

        let packet_type = serde::deserialize_u8(&vector_slice(payload, 0, 1));
        assert!(packet_type == PRECEIVE, error::aborted(EBRIDGE_INVALID_PACKET_TYPE));

        let remote_token_addr = vector_slice(payload, 1, 33);
        let receiver_bytes = vector_slice(payload, 33, 65);
        let amount_sd = serde::deserialize_u64(&vector_slice(payload, 65, 73));
        (remote_token_addr, receiver_bytes, amount_sd)
    }

    fun check_adapter_params(dst_chain_id: u64, adapter_params: &vector<u8>) acquires Config {
        let config = borrow_global<Config>(@bridge);
        if (config.custom_adapter_params) {
            lzapp::assert_gas_limit(@bridge, dst_chain_id,  (PSEND as u64), adapter_params, 0);
        } else {
            assert!(vector::is_empty(adapter_params), error::invalid_argument(EBRIDGE_INVALID_ADAPTER_PARAMS));
        }
    }

    fun assert_registered_token<CoinType>() {
        assert!(has_token_registered<CoinType>(), error::permission_denied(EBRIDGE_UNREGISTERED_TOKEN));
    }

    fun assert_unpaused<CoinType>() acquires Config {
        let config = borrow_global<Config>(@bridge);
        assert!(!config.paused_global, error::unavailable(EBRIDGE_PAUSED));

        let token_type = type_info::type_of<CoinType>();
        if (table::contains(&config.paused_tokens, token_type)) {
            assert!(!*table::borrow(&config.paused_tokens, token_type), error::unavailable(EBRIDGE_PAUSED));
        }
    }
}