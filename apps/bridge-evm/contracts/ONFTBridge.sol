// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8;

import "./ONFT721Enumerable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract ONFTBridge is ONFT721Enumerable, ReentrancyGuard {
    using Strings for uint;

    string private baseURI;

    constructor(
        string memory _name,
        string memory _symbol,
        address _layerZeroEndpoint,
        string memory _baseTokenURI
    ) ONFT721Enumerable(_name, _symbol, _layerZeroEndpoint) {
        baseURI = _baseTokenURI;
    }

    function setBaseURI(string memory uri) public onlyOwner {
        baseURI = uri;
    }

    // The following functions are overrides required by Solidity.
    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    function tokenURI(uint tokenId) public view override(ERC721) returns (string memory) {
        require(_exists(tokenId), "ERC721Metadata: URI query for nonexistent token");
        return string(abi.encodePacked(_baseURI(), tokenId.toString()));
    }

    function testMint(uint tokenId) external onlyOwner {
        _safeMint(msg.sender, tokenId);
    }
}
