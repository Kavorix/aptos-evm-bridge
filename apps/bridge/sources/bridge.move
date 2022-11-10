module bridge::onft_bridge {
    use std::error;
    use std::vector;
    use std::string::{Self, String};
    use std::signer::{address_of};
    use std::bcs;

    use aptos_std::table::{Self, Table};
    use aptos_std::event::{Self, EventHandle};
    use aptos_std::from_bcs::to_address;

    use aptos_token::token::{Self, TokenId, get_token_id_fields};
    use aptos_framework::account;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin;

    use layerzero_common::serde;
    use layerzero_common::utils::{vector_slice, assert_u16, assert_signer, assert_length};
    use layerzero::endpoint::{Self, UaCapability};
    use layerzero::lzapp;
    use layerzero::remote;
    use zro::zro::ZRO;

    const EBRIDGE_UNREGISTERED_COLLECTION: u64 = 0x00;
    const EBRIDGE_CLAIMABLE_TOKEN_NOT_FOUND: u64 = 0x01;
    const EBRIDGE_INVALID_PACKET_TYPE: u64 = 0x02;
    const EBRIDGE_PAUSED: u64 = 0x03;
    const EBRIDGE_INVALID_ADAPTER_PARAMS: u64 = 0x04;

    // paceket type, in line with EVM
    const PRECEIVE: u8 = 0;
    const PSEND: u8 = 1;

    const SEND_PAYLOAD_SIZE: u64 = 29;

    // layerzero user application generic type for this app
    struct BridgeUA {}

    struct Path has copy, drop {
        remote_chain_id: u64,
        remote_token_addr: vector<u8>,
    }

    struct LzCapability has key {
        cap: UaCapability<BridgeUA>
    }

    struct Config has key {
        paused_global: bool,
        custom_adapter_params: bool,
        collection_name: String
    }

    struct ClaimData has copy, drop, key {
        token_id: u64,
        receiver_addr: address
    }

    struct CollectionStore has key {
        // chain id of remote coins
        remote_chains: vector<u64>,
        claimable_id: Table<ClaimData, bool>,
    }

    struct EventStore has key {
        send_events: EventHandle<SendEvent>,
        receive_events: EventHandle<ReceiveEvent>,
        claim_events: EventHandle<ClaimEvent>,
    }

    struct SendEvent has drop, store {
        collection: string::String,
        dst_chain_id: u64,
        dst_receiver: vector<u8>,
        token_id: u64,
    }

    struct ReceiveEvent has drop, store {
        src_chain_id: u64,
        receiver: address,
        token_id: u64,
    }

    struct ClaimEvent has drop, store {
        receiver: address,
        token_id: u64,
    }

    struct CollectionTokenMinter has key {
        signer_cap: account::SignerCapability,
    }

    fun init_module(account: &signer) {
        let cap = endpoint::register_ua<BridgeUA>(account);
        let collection_uri = string::utf8(b"https://arweave.net/lSdEW6BafylhrF-1WZP3YQTMI8VPB0OBcM4SpInPnsk/1");

        // create the nft collection
        let maximum_supply = 1000;
        let mutate_setting = vector<bool>[ false, false, false ];
        lzapp::init(account, cap);
        remote::init(account);

        move_to(account, LzCapability { cap });

        move_to(account, Config {
            paused_global: false,
            custom_adapter_params: false,
            collection_name: get_collection_name(),
        });

        move_to(account, CollectionStore {
            remote_chains: vector::empty(),
            claimable_id: table::new(),
        });

        move_to(account, EventStore {
            send_events: account::new_event_handle<SendEvent>(account),
            receive_events: account::new_event_handle<ReceiveEvent>(account),
            claim_events: account::new_event_handle<ClaimEvent>(account),
        });
        let (resource_signer, resource_signer_cap) = account::create_resource_account(account, b"bridge");
        token::create_collection(&resource_signer, get_collection_name(), get_collection_description(), collection_uri, maximum_supply, mutate_setting);
        
        move_to(account, CollectionTokenMinter {
            signer_cap: resource_signer_cap,
        });
    }

    public fun get_collection_name(): String {
        use std::string;
        string::utf8(b"ONFT")
    }

    public fun get_collection_description(): String {
        use std::string;
        string::utf8(b"ONFT")
    }

    public fun get_token_uri(token_id: u64): String {
        use std::string;
        let token_uri = string::utf8(b"https://arweave.net/lSdEW6BafylhrF-1WZP3YQTMI8VPB0OBcM4SpInPnsk/");
        let token_id_in_string = to_string(token_id);
        string::append(&mut token_uri, token_id_in_string);
        token_uri
    }

    public entry fun set_global_pause(account: &signer, paused: bool) acquires Config {
        assert_signer(account, @bridge);

        let config = borrow_global_mut<Config>(@bridge);
        config.paused_global = paused;
    }


    public entry fun enable_custom_adapter_params(account: &signer, enabled: bool) acquires Config {
        assert_signer(account, @bridge);

        let config = borrow_global_mut<Config>(@bridge);
        config.custom_adapter_params = enabled;
    }

    //
    // token transfer functions
    //
    public entry fun send_token(
        account: &signer,
        creator: address,
        collection_name: vector<u8>,
        token_name: vector<u8>,
        property_version: u64,
        dst_chain_id: u64,
        dst_receiver: vector<u8>,
        tx_fee: u64,
        adapter_params: vector<u8>,
        msglib_params: vector<u8>,
    ) acquires CollectionTokenMinter, EventStore, Config, LzCapability {
        let token_id = token::create_token_id_raw(creator, string::utf8(collection_name), string::utf8(token_name), property_version);
        let fee = coin::withdraw<AptosCoin>(account, tx_fee);
        let (native_refund, zro_refund) = send_token_with_zro(account, token_id, dst_chain_id, dst_receiver, fee, coin::zero<ZRO>(), adapter_params, msglib_params);
        coin::destroy_zero(zro_refund);
        coin::deposit<AptosCoin>(address_of(account), native_refund);
    }

    public fun send_token_with_zro(
        account: &signer,
        token_id: TokenId,
        dst_chain_id: u64,
        dst_receiver: vector<u8>,
        native_fee: Coin<AptosCoin>,
        zro_fee: Coin<ZRO>,
        adapter_params: vector<u8>,
        msglib_params: vector<u8>,
    ): (Coin<AptosCoin>, Coin<ZRO>) acquires CollectionTokenMinter, EventStore, Config, LzCapability {

        let (native_refund, zro_refund) = send_token_internal(account, token_id, dst_chain_id, dst_receiver, native_fee, zro_fee, adapter_params, msglib_params);
        (native_refund, zro_refund)
    }

    fun send_token_internal(
        account: &signer,
        token_id: TokenId,
        dst_chain_id: u64,
        dst_receiver: vector<u8>,
        native_fee: Coin<AptosCoin>,
        zro_fee: Coin<ZRO>,
        adapter_params: vector<u8>,
        msglib_params: vector<u8>,
    ): (Coin<AptosCoin>, Coin<ZRO>) acquires CollectionTokenMinter, EventStore, Config, LzCapability {
        let (creator, collection_name, token_name, _) = get_token_id_fields(&token_id);

        assert_registered_collection(creator, collection_name);
        assert_unpaused();
        assert_u16(dst_chain_id);
        assert_length(&dst_receiver, 20);

        // burn the token
        token::burn(account, creator, collection_name, token_name, 0, 1);

        // check gas limit with adapter params
        check_adapter_params(dst_chain_id, &adapter_params);

        let payload = encode_send_payload(dst_receiver, serde::deserialize_u64(string::bytes(&token_name)));

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
                collection: collection_name,
                dst_chain_id,
                dst_receiver,
                token_id: serde::deserialize_u64(string::bytes(&token_name)),
            },
        );

        (native_refund, zro_refund)
    }

    public entry fun lz_receive(src_chain_id: u64, src_address: vector<u8>, payload: vector<u8>) acquires CollectionStore, EventStore, Config, LzCapability {
        assert_unpaused();
        assert_u16(src_chain_id);

        // assert the payload is valid
        remote::assert_remote(@bridge, src_chain_id, src_address);
        let lz_cap = borrow_global<LzCapability>(@bridge);
        endpoint::lz_receive<BridgeUA>(src_chain_id, src_address, payload, &lz_cap.cap);

        // decode payload and get token amount
        let (receiver_bytes, token_id) = decode_receive_payload(&payload);

        // stash if the receiver has not yet registered to receive the token
        let receiver = to_address(receiver_bytes);
        
        let collection_store = borrow_global_mut<CollectionStore>(@bridge);
        let status = table::borrow_mut_with_default(&mut collection_store.claimable_id, ClaimData {token_id, receiver_addr: receiver}, false);
        *status = true;

        // emit event
        let event_store = borrow_global_mut<EventStore>(@bridge);
        event::emit_event(
            &mut event_store.receive_events,
            ReceiveEvent {
                src_chain_id,
                receiver,
                token_id,
            }
        );
    }

    public entry fun claim_token(receiver: &signer, token_id: u64) acquires CollectionTokenMinter, CollectionStore, EventStore, Config {
        assert_unpaused();

        token::initialize_token_store(receiver);
        // register the user if needed
        let receiver_addr = address_of(receiver);

        // assert the receiver has receivable and it is more than 0
        let token_store = borrow_global_mut<CollectionStore>(@bridge);
        assert!(table::contains(&token_store.claimable_id, ClaimData {token_id, receiver_addr}), error::not_found(EBRIDGE_CLAIMABLE_TOKEN_NOT_FOUND));
        let claimable_ld = table::remove(&mut token_store.claimable_id, ClaimData {token_id, receiver_addr});
        assert!(claimable_ld, error::not_found(EBRIDGE_CLAIMABLE_TOKEN_NOT_FOUND));

        let default_keys = vector<String>[ string::utf8(b"attack"), string::utf8(b"num_of_use") , string::utf8(b"TOKEN_BURNABLE_BY_OWNER")];
        let default_vals = vector<vector<u8>>[ bcs::to_bytes<u64>(&10), bcs::to_bytes<u64>(&5),bcs::to_bytes<bool>(&true)];
        let default_types = vector<String>[ string::utf8(b"u64"), string::utf8(b"u64") , string::utf8(b"bool")];
        let mutate_setting = vector<bool>[ false, false, false, false, false, false ];
        let collection_token_minter = borrow_global_mut<CollectionTokenMinter>(@bridge);
        let resource_signer = account::create_signer_with_capability(&collection_token_minter.signer_cap);
        let token_name = to_string(token_id);

        token::create_token_script(
            &resource_signer,
            get_collection_name(),
            token_name,
            string::utf8(b"Token Description"),
            1,
            1,
            get_token_uri(token_id),
            @bridge,
            100,
            0,
            mutate_setting,
            default_keys,
            default_vals,
            default_types,
        );
        let token = token::create_token_id_raw(address_of(&resource_signer), get_collection_name(), token_name, 0);

        let minted_token = token::withdraw_token(&resource_signer, token, 1);
        token::deposit_token(receiver, minted_token);

        // // emit event
        let event_store = borrow_global_mut<EventStore>(@bridge);
        event::emit_event(
            &mut event_store.claim_events,
            ClaimEvent {
                receiver: receiver_addr,
                token_id: token_id
            }
        );
    }

    public fun quote_fee(dst_chain_id: u64, pay_in_zro: bool, adapter_params: vector<u8>, msglib_params: vector<u8>): (u64, u64) {
        endpoint::quote_fee(@bridge, dst_chain_id, SEND_PAYLOAD_SIZE, pay_in_zro, adapter_params, msglib_params)
    }

    // encode payload: packet type(1) + receiver(32) + token_id(8)
    fun encode_send_payload(dst_receiver: vector<u8>, token_id: u64): vector<u8> {
        assert_length(&dst_receiver, 20);

        let payload = vector::empty<u8>();
        serde::serialize_u8(&mut payload, PSEND);
        serde::serialize_vector(&mut payload, dst_receiver);
        serde::serialize_u64(&mut payload, token_id);
        payload
    }

    // decode payload: packet type(1) + receiver(32) + token_id(8)
    fun decode_receive_payload(payload: &vector<u8>): (vector<u8>, u64) {
        assert_length(payload, 41);

        let packet_type = serde::deserialize_u8(&vector_slice(payload, 0, 1));
        assert!(packet_type == PRECEIVE, error::aborted(EBRIDGE_INVALID_PACKET_TYPE));

        let receiver_bytes = vector_slice(payload, 1, 33);
        let token_id = serde::deserialize_u64(&vector_slice(payload, 33, 41));
        (receiver_bytes, token_id)
    }

    fun check_adapter_params(dst_chain_id: u64, adapter_params: &vector<u8>) acquires Config {
        let config = borrow_global<Config>(@bridge);
        if (config.custom_adapter_params) {
            lzapp::assert_gas_limit(@bridge, dst_chain_id,  (PSEND as u64), adapter_params, 0);
        } else {
            assert!(vector::is_empty(adapter_params), error::invalid_argument(EBRIDGE_INVALID_ADAPTER_PARAMS));
        }
    }

    fun assert_registered_collection(creator: address, collection_name: String) acquires CollectionTokenMinter, Config {
        let config = borrow_global<Config>(@bridge);
        let collection_token_minter = borrow_global_mut<CollectionTokenMinter>(@bridge);
        let resource_signer = account::create_signer_with_capability(&collection_token_minter.signer_cap);
        assert!(
            address_of(&resource_signer) == creator && collection_name == config.collection_name,
            error::not_found(EBRIDGE_UNREGISTERED_COLLECTION),
        );
    }

    fun assert_unpaused() acquires Config {
        let config = borrow_global<Config>(@bridge);
        assert!(!config.paused_global, error::unavailable(EBRIDGE_PAUSED));
    }

    fun to_string(value: u64): String {
        if (value == 0) {
            return string::utf8(b"0")
        };
        let buffer = vector::empty<u8>();
        while (value != 0) {
            vector::push_back(&mut buffer, ((48 + value % 10) as u8));
            value = value / 10;
        };
        vector::reverse(&mut buffer);
        string::utf8(buffer)
    }

    #[test(creator = @creator)]
    public entry fun create_resource_account(creator: signer) {
        use aptos_framework::account;
        use aptos_std::debug;
        use std::signer;
        let creator_addr = signer::address_of(&creator);
        let seed = b"bridge";
        let addr = account::create_resource_address(&creator_addr, seed);
        debug::print(&addr);
    }
}