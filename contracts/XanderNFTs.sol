//SPDX-License-Identifier: MIT
// contracts/ERC721.sol

pragma solidity >=0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

// Based on https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5e34a84d4a5f45fb9a50eeef2aa39f894b9ac7ad/docs/modules/ROOT/pages/erc721.adoc

contract XanderNFTs is ERC721 {
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;

    constructor() ERC721("Xander", "XAN") {}

    // FIXME: This can be called by anyone - this is not right
    // commented out unused variable
    // function awardItem(address player, string memory tokenURI)
    function awardItem(address player) external returns (uint256) {
        _tokenIds.increment();

        uint256 newItemId = _tokenIds.current();
        _mint(player, newItemId);
        // _setTokenURI(newItemId, tokenURI);

        return newItemId;
    }
}
