// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/// @author: manifold.xyz

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "manifoldxyz-creator-core-solidity/contracts/core/IERC721CreatorCore.sol";
import "manifoldxyz-creator-core-solidity/contracts/extensions/CreatorExtensionBase.sol";
import "manifoldxyz-libraries-solidity/contracts/access/AdminControl.sol";

import "./IBurnRedeem.sol";

struct range{
   uint256 min;
   uint256 max;
}

/**
 * @dev Burn NFT's to receive another lazy minted NFT
 */
contract BurnRedeem is ReentrancyGuard, AdminControl, CreatorExtensionBase, IBurnRedeem {
     using EnumerableSet for EnumerableSet.UintSet;

     // The creator mint contract
     address _creator;

     mapping (address => mapping (uint256 => address)) private _recoverableERC721;

     uint16 private immutable _redemptionRate;
     uint16 private _redemptionMax;
     uint16 private _redemptionCount;
     uint256[] private _mintedTokens;
     mapping(uint256 => uint256) _mintNumbers;

     // approved burnable contract tokens
    mapping(address => bool) private _approvedContracts;

    // approved burnable specific tokens
    mapping(address => EnumerableSet.UintSet) private _approvedTokens;
    mapping(address => range[]) private _approvedTokenRange;
     
    constructor(address creator, uint16 redemptionRate_, uint16 redemptionMax_) {
        require(ERC165Checker.supportsInterface(creator, type(IERC721CreatorCore).interfaceId), "BurnRedeem: Minting reward contract must implement IERC721CreatorCore");
        _redemptionRate = redemptionRate_;
        _redemptionMax = redemptionMax_;
        _creator = creator;
    }     

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(AdminControl, CreatorExtensionBase, IERC165) returns (bool) {
        return interfaceId == type(IBurnRedeem).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /**
     * @dev See {IBurnRedeem-setERC721Recoverable}
     */
    function setERC721Recoverable(address contract_, uint256 tokenId, address recoverer) external virtual override adminRequired {
        require(ERC165Checker.supportsInterface(contract_, type(IERC721).interfaceId), "BurnRedeem: Must implement IERC721");
        _recoverableERC721[contract_][tokenId] = recoverer;
    }

    /**
     * @dev See {IBurnRedeem-updateApprovedContracts}
     */
    function updateApprovedContracts(address[] calldata contracts, bool[] calldata approved) external virtual override adminRequired {
        require(contracts.length == approved.length, "BurnRedeem: Invalid input parameters");
        for (uint i=0; i < contracts.length; i++) {
            _approvedContracts[contracts[i]] = approved[i];
        }
    }
    
    /**
     * @dev See {IBurnRedeem-updateApprovedTokens}
     */
    function updateApprovedTokens(address contract_, uint256[] calldata tokenIds, bool[] calldata approved) external virtual override adminRequired {
        require(tokenIds.length == approved.length, "BurnRedeem: Invalid input parameters");

        for (uint i=0; i < tokenIds.length; i++) {
            if (approved[i] && !_approvedTokens[contract_].contains(tokenIds[i])) {
                _approvedTokens[contract_].add(tokenIds[i]);
            } else if (!approved[i] && _approvedTokens[contract_].contains(tokenIds[i])) {
                _approvedTokens[contract_].remove(tokenIds[i]);
            }
        }
    }

    /**
     * @dev See {IBurnRedeem-updateApprovedTokenRanges}
     */
    function updateApprovedTokenRanges(address contract_, uint256[] calldata minTokenIds, uint256[] calldata maxTokenIds) external virtual override adminRequired {
        require(minTokenIds.length == maxTokenIds.length, "BurnRedeem: Invalid input parameters");
        
        uint existingRangesLength = _approvedTokenRange[contract_].length;
        for (uint i=0; i < existingRangesLength; i++) {
            _approvedTokenRange[contract_][i].min = 0;
            _approvedTokenRange[contract_][i].max = 0;
        }
        
        for (uint i=0; i < minTokenIds.length; i++) {
            require(minTokenIds[i] < maxTokenIds[i], "BurnRedeem: min must be less than max");
            if (i < existingRangesLength) {
                _approvedTokenRange[contract_][i].min = minTokenIds[i];
                _approvedTokenRange[contract_][i].max = maxTokenIds[i];
            } else {
                _approvedTokenRange[contract_].push(range(minTokenIds[i], maxTokenIds[i]));
            }
        }
    }

    /**
     * @dev See {IBurnRedeem-recoverERC721}
     */
    function recoverERC721(address contract_, uint256 tokenId) external virtual override {
        address recoverer = _recoverableERC721[contract_][tokenId];
        require(recoverer == msg.sender, "BurnRedeem: Permission denied");
        IERC721(contract_).safeTransferFrom(address(this), msg.sender, tokenId);
    }

    /**
     * @dev See {IBurnRedeem-redeemERC721}
     */
    function redeemERC721(address[] calldata contracts, uint256[] calldata tokenIds) external virtual override nonReentrant {
        require(contracts.length == tokenIds.length, "BurnRedeem: Invalid parameters");
        require(contracts.length == _redemptionRate, "BurnRedeem: Incorrect number of NFTs being redeemed");
        require(_redemptionCount < _redemptionMax, "BurnRedeem: No redemptions remaining");

        // Attempt Burn
        for (uint i=0; i<contracts.length; i++) {
            // Check that we can burn
            require(redeemable(contracts[i], tokenIds[i]), "BurnRedeem: Invalid NFT");

            try IERC721(contracts[i]).ownerOf(tokenIds[i]) returns (address ownerOfAddress) {
                require(ownerOfAddress == msg.sender, "BurnRedeem: Caller must own NFTs");
            } catch (bytes memory) {
                revert("BurnRedeem: Bad token contract");
            }

            try IERC721(contracts[i]).getApproved(tokenIds[i]) returns (address approvedAddress) {
                require(approvedAddress == address(this), "BurnRedeem: Contract must be given approval to burn NFT");
            } catch (bytes memory) {
                revert("BurnRedeem: Bad token contract");
            }
            

            // Then burn
            try IERC721(contracts[i]).transferFrom(msg.sender, address(0xdEaD), tokenIds[i]) {
            } catch (bytes memory) {
                revert("BurnRedeem: Burn failure");
            }
        }

        _redemptionCount++;

        // Mint reward
        try IERC721CreatorCore(_creator).mintExtension(msg.sender) returns(uint256 newTokenId) {
            _mintedTokens.push(newTokenId);
            _mintNumbers[newTokenId] = _redemptionCount;
        } catch (bytes memory) {
            revert("BurnRedeem: Redemption failure");
        }
    }

    /**
     * @dev See {IBurnRedeem-redemptionRate}
     */
    function redemptionRate() external view virtual override returns(uint16) {
        return _redemptionRate;
    }

    /**
     * @dev See {IBurnRedeem-redemptionRemaining}
     */
    function redemptionRemaining() external view virtual override returns(uint16) {
        return _redemptionMax-_redemptionCount;
    }

    /**
     * @dev See {IBurnRedeem-redeemable}
     */    
    function redeemable(address contract_, uint256 tokenId) public view virtual override returns(bool) {
        require(_redemptionCount < _redemptionMax, "BurnRedeem: No redemptions remaining");

         if (_approvedContracts[contract_]) {
             return true;
         }
         if (_approvedTokens[contract_].contains(tokenId)) {
             return true;
         }
         if (_approvedTokenRange[contract_].length > 0) {
             for (uint i=0; i < _approvedTokenRange[contract_].length; i++) {
                 if (_approvedTokenRange[contract_][i].max != 0 && tokenId >= _approvedTokenRange[contract_][i].min && tokenId <= _approvedTokenRange[contract_][i].max) {
                     return true;
                 }
             }
         }
         return false;
    }

    /**
     * @dev See {IERC721Receiver-onERC721Received}.
     */
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata data) external override nonReentrant returns (bytes4) {
        require(redeemable(msg.sender, tokenId), "BurnRedeem: Invalid NFT");
        require(_redemptionRate == 1, "BurnRedeem: Can only allow direct receiving of redemptions of 1 NFT");
        
        _redemptionCount++;
        
        // Burn it
        try IERC721(msg.sender).safeTransferFrom(address(this), address(0xdEaD), tokenId, data) {
        } catch (bytes memory) {
            revert("BurnRedeem: Burn failure");
        }

        // Mint reward
        try IERC721CreatorCore(_creator).mintExtension(from) returns(uint256 newTokenId) {
            _mintNumbers[newTokenId] = _redemptionCount;
        } catch (bytes memory) {
            revert("BurnRedeem: Redemption failure");
        }

        return this.onERC721Received.selector;
    }


    /**
     * @dev See {IERC1155Receiver-onERC1155Received}.
     */
    function onERC1155Received(
        address,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) external override nonReentrant returns(bytes4) {
        require(redeemable(msg.sender, id), "BurnRedeem: Invalid NFT");
        require(value == _redemptionRate, "BurnRedeem: Incorrect number of NFTs being redeemed");

        _redemptionCount++;
        
        // Burn it
        try IERC1155(msg.sender).safeTransferFrom(address(this), address(0xdEaD), id, value, data) {
        } catch (bytes memory) {
            revert("BurnRedeem: Burn failure");
        }

        // Mint reward
        try IERC721CreatorCore(_creator).mintExtension(from) returns(uint256 newTokenId) {
            _mintNumbers[newTokenId] = _redemptionCount;
        } catch (bytes memory) {
            revert("BurnRedeem: Redemption failure");
        }

        return this.onERC1155Received.selector;
    }

    /**
     * @dev See {IERC1155Receiver-onERC1155BatchReceived}.
     */
    function onERC1155BatchReceived(
        address,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external override nonReentrant returns(bytes4) {
        require(ids.length == values.length, "BurnRedeem: Invalid input");

        uint256 totalValue = 0;
        for (uint i=0; i<ids.length; i++) {
            require(redeemable(msg.sender, ids[i]), "BurnRedeem: Invalid NFT");
            totalValue += values[i];
        }

        require(totalValue == _redemptionRate, "BurnRedeem: Incorrect number of NFTs being redeemed");

        _redemptionCount++;

        // Burn it
        try IERC1155(msg.sender).safeBatchTransferFrom(address(this), address(0xdEaD), ids, values, data) {
        } catch (bytes memory) {
            revert("BurnRedeem: Burn failure");
        }

        // Mint reward
        try IERC721CreatorCore(_creator).mintExtension(from) returns(uint256 newTokenId) {
            _mintNumbers[newTokenId] = _redemptionCount;
        } catch (bytes memory) {
            revert("BurnRedeem: Redemption failure");
        }

        return this.onERC1155BatchReceived.selector;
    }

    /**
     * @dev See {IBurnRedeem-mintNumber}.
     */
    function mintNumber(uint256 tokenId) external view override returns(uint256) {
        return _mintNumbers[tokenId];
    }

    /**
     * @dev See {IBurnRedeem-mintedTokens}.
     */
    function mintedTokens() external view override returns(uint256[] memory) {
        return _mintedTokens;
    }

}