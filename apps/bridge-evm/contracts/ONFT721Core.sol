// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "@layerzerolabs/solidity-examples/contracts/lzApp/NonblockingLzApp.sol";
import "@layerzerolabs/solidity-examples/contracts/libraries/LzLib.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "./interfaces/IONFT721Core.sol";

abstract contract ONFT721Core is NonblockingLzApp, ERC165, IONFT721Core {
    bool public useCustomAdapterParams;

    enum PacketType {
        SEND_TO_APTOS,
        RECEIVE_FROM_APTOS
    }

    constructor(address _lzEndpoint) NonblockingLzApp(_lzEndpoint) {}

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IONFT721Core).interfaceId || super.supportsInterface(interfaceId);
    }

    function setUseCustomAdapterParams(bool _useCustomAdapterParams) external onlyOwner {
        useCustomAdapterParams = _useCustomAdapterParams;
    }

    function estimateSendFee(uint16 _dstChainId, bytes32, uint, bool _useZro, bytes calldata _adapterParams) public view virtual override returns (uint nativeFee, uint zroFee) {
        // mock the payload for send()
        _checkAdapterParams(_dstChainId, _adapterParams);
        bytes memory payload = _encodeSendPayload(bytes32(0), 0);
        return
            lzEndpoint.estimateFees(_dstChainId, address(this), payload, _useZro, _adapterParams);
    }

    function sendFrom(address _from, uint16 _dstChainId, bytes32 _toAddress, uint _tokenId, address payable _refundAddress, address _zroPaymentAddress, bytes calldata _adapterParams) public payable virtual override {
        _checkAdapterParams(_dstChainId, _adapterParams);
        _send(_from, _dstChainId, _toAddress, _tokenId, _refundAddress, _zroPaymentAddress, _adapterParams, msg.value);
    }

    function _send(address _from, uint16 _dstChainId, bytes32 _toAddress, uint _tokenId, address payable _refundAddress, address _zroPaymentAddress, bytes memory _adapterParams, uint _fee) internal virtual {
        _debitFrom(_from, _dstChainId, _toAddress, _tokenId);

        bytes memory payload = _encodeSendPayload(_toAddress, uint64(_tokenId));
        _lzSend(_dstChainId, payload, _refundAddress, _zroPaymentAddress, _adapterParams, _fee);

        uint64 nonce = lzEndpoint.getOutboundNonce(_dstChainId, address(this));
        emit SendToChain(_from, _dstChainId, _toAddress, _tokenId, nonce);
    }

    function _nonblockingLzReceive(uint16 _srcChainId, bytes memory _srcAddress, uint64 _nonce, bytes memory _payload) internal virtual override {
        // decode and load the toAddress
        (address toAddress, uint64 tokenId) = _decodeReceivePayload(_payload);

        _creditTo(_srcChainId, toAddress, tokenId);

        emit ReceiveFromChain(_srcChainId, _srcAddress, toAddress, tokenId, _nonce);
    }

    function _checkAdapterParams(uint16 _dstChainId, bytes calldata _adapterParams) internal view {
        if (useCustomAdapterParams) {
            _checkGasLimit(_dstChainId, uint16(PacketType.SEND_TO_APTOS), _adapterParams, 0);
        } else {
            require(_adapterParams.length == 0, "TokenBridge: _adapterParams must be empty.");
        }
    }

    // send payload: packet type(1) + remote token(32) + receiver(32) + amount(8)
    function _encodeSendPayload(
        bytes32 _toAddress,
        uint64 _tokenID
    ) internal pure returns (bytes memory) {
        return
            abi.encodePacked(uint8(PacketType.SEND_TO_APTOS), _toAddress, _tokenID);
    }

    // receive payload: packet type(1) + receiver(32) + token_id(8) 
    function _decodeReceivePayload(bytes memory _payload)
        internal
        pure
        returns (
            address toAddress,
            uint64 tokenID
        )
    {
        require(_payload.length == 41, "ONFTBridge: invalid payload length");
        PacketType packetType = PacketType(uint8(_payload[0]));
        require(packetType == PacketType.RECEIVE_FROM_APTOS, "ONFTBridge: unknown packet type");
        assembly {
            toAddress := mload(add(_payload, 33))
            tokenID := mload(add(_payload, 41))
        }
    }

    function _debitFrom(address _from, uint16 _dstChainId, bytes32 _toAddress, uint _tokenId) internal virtual;

    function _creditTo(uint16 _srcChainId, address _toAddress, uint _tokenId) internal virtual;
}