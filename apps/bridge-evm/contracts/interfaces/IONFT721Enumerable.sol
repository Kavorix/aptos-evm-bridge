// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "./IONFT721Core.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

/**
 * @dev Interface of the ONFTEnumerable standard
 */
interface IONFT721Enumerable is IONFT721Core, IERC721Enumerable {

}