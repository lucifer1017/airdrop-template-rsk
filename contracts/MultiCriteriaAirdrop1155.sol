// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

interface IERC1155 {
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes memory data) external;
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

interface IStakingContract {
    function stakedBalance(address user) external view returns (uint256);
    function stakingDuration(address user) external view returns (uint256);
}

interface IRNSRegistry {
    function owner(bytes32 node) external view returns (address);
    function recordExists(bytes32 node) external view returns (bool);
}

enum AirdropType {
    CUSTOM,
    MERKLE,
    MULTI_CRITERIA
}

struct AirdropInfo {
    string airdropName;
    address airdropAddress;
    uint256 totalAirdropAmount;
    uint256 airdropAmountLeft;
    uint256 claimAmount;
    uint256 expirationDate;
    AirdropType airdropType;
}

struct EligibilityCriteria {
    // Staking criteria
    address stakingContract;
    uint256 minimumStakeAmount;
    uint256 minimumStakeDuration;
    
    // On-chain activity criteria
    uint256 minimumTransactions;
    uint256 minimumContractInteractions;
    
    // RNS domain criteria
    address rnsRegistry;
    bytes32[] requiredDomains;
    bool requireAnyDomain;
    
    // Scoring weights (out of 100)
    uint256 stakingWeight;
    uint256 activityWeight;
    uint256 rnsWeight;
    uint256 minimumScore;
}

contract MultiCriteriaAirdrop1155 is Ownable {
    event Claim(address recipient, uint256 amount);
    event CriteriaUpdated(address indexed admin);
    event ScoreCalculated(address indexed user, uint256 stakingScore, uint256 activityScore, uint256 rnsScore, uint256 totalScore);

    IERC1155 _tokenContract;
    uint256 _totalAirdropAmount;
    uint256 _airdropAmountLeft;
    uint256 _claimAmount;
    uint256 _expirationDate;
    uint256 _tokenId;
    string _airdropName;
    AirdropType _airdropType;

    EligibilityCriteria public eligibilityCriteria;
    
    mapping(address => bool) _addressesThatAlreadyClaimed;
    mapping(address => uint256) public userScores;
    mapping(address => uint256) public transactionCounts;
    mapping(address => uint256) public contractInteractionCounts;

    // Events tracking for on-chain activity
    event TransactionTracked(address indexed user);
    event ContractInteractionTracked(address indexed user, address indexed contractAddress);

    constructor(
        string memory airdropName,
        address initialOwner,
        address tokenAddress,
        uint256 tokenId,
        uint256 totalAirdropAmount,
        uint256 claimAmount,
        uint256 expirationDate,
        EligibilityCriteria memory criteria
    ) Ownable(initialOwner) {
        _tokenContract = IERC1155(tokenAddress);
        _airdropName = airdropName;
        _tokenId = tokenId;
        _totalAirdropAmount = totalAirdropAmount;
        _airdropAmountLeft = totalAirdropAmount;
        _claimAmount = claimAmount;
        _expirationDate = expirationDate;
        _airdropType = AirdropType.MULTI_CRITERIA;
        
        eligibilityCriteria = criteria;
        
        // Ensure weights add up to 100
        require(
            criteria.stakingWeight + criteria.activityWeight + criteria.rnsWeight == 100,
            "Weights must sum to 100"
        );
    }

    function claim(address user, uint256 , bytes32[] calldata) public onlyOwner {
        require(isAllowed(user), "User does not meet eligibility criteria");
        require(!hasExpired(), "Airdrop already expired");
        require(!hasClaimed(user), "Address already claimed this airdrop");
        require(!hasBeenTotallyClaimed(), "Airdrop has been totally claimed already");
        require(hasBalanceToClaim(), "Airdrop contract has insufficient token balance");

        _tokenContract.safeTransferFrom(address(this), user, _tokenId, _claimAmount, '');
        _airdropAmountLeft -= _claimAmount;
        _addressesThatAlreadyClaimed[user] = true;

        emit Claim(user, _claimAmount);
    }

    function calculateUserScore(address user) public returns (uint256) {
        uint256 stakingScore = _calculateStakingScore(user);
        uint256 activityScore = _calculateActivityScore(user);
        uint256 rnsScore = _calculateRNSScore(user);
        
        uint256 totalScore = (stakingScore * eligibilityCriteria.stakingWeight +
                             activityScore * eligibilityCriteria.activityWeight +
                             rnsScore * eligibilityCriteria.rnsWeight) / 100;
        
        userScores[user] = totalScore;
        
        emit ScoreCalculated(user, stakingScore, activityScore, rnsScore, totalScore);
        
        return totalScore;
    }

    function _calculateStakingScore(address user) internal view returns (uint256) {
        if (eligibilityCriteria.stakingContract == address(0)) return 0;
        
        IStakingContract stakingContract = IStakingContract(eligibilityCriteria.stakingContract);
        
        uint256 stakedAmount = stakingContract.stakedBalance(user);
        uint256 stakingDuration = stakingContract.stakingDuration(user);
        
        // Score based on staking amount (0-50 points)
        uint256 amountScore = 0;
        if (stakedAmount >= eligibilityCriteria.minimumStakeAmount) {
            amountScore = 25 + (stakedAmount * 25) / (eligibilityCriteria.minimumStakeAmount * 2);
            if (amountScore > 50) amountScore = 50;
        }
        
        // Score based on staking duration (0-50 points)
        uint256 durationScore = 0;
        if (stakingDuration >= eligibilityCriteria.minimumStakeDuration) {
            durationScore = 25 + (stakingDuration * 25) / (eligibilityCriteria.minimumStakeDuration * 2);
            if (durationScore > 50) durationScore = 50;
        }
        
        return amountScore + durationScore;
    }

    function _calculateActivityScore(address user) internal view returns (uint256) {
        uint256 txCount = transactionCounts[user];
        uint256 contractInteractions = contractInteractionCounts[user];
        
        // Score based on transaction count (0-50 points)
        uint256 txScore = 0;
        if (txCount >= eligibilityCriteria.minimumTransactions) {
            txScore = 25 + (txCount * 25) / (eligibilityCriteria.minimumTransactions * 2);
            if (txScore > 50) txScore = 50;
        }
        
        // Score based on contract interactions (0-50 points)
        uint256 interactionScore = 0;
        if (contractInteractions >= eligibilityCriteria.minimumContractInteractions) {
            interactionScore = 25 + (contractInteractions * 25) / (eligibilityCriteria.minimumContractInteractions * 2);
            if (interactionScore > 50) interactionScore = 50;
        }
        
        return txScore + interactionScore;
    }

    function _calculateRNSScore(address user) internal view returns (uint256) {
        if (eligibilityCriteria.rnsRegistry == address(0)) return 0;
        
        IRNSRegistry rnsRegistry = IRNSRegistry(eligibilityCriteria.rnsRegistry);
        uint256 ownedDomains = 0;
        
        for (uint i = 0; i < eligibilityCriteria.requiredDomains.length; i++) {
            bytes32 domain = eligibilityCriteria.requiredDomains[i];
            if (rnsRegistry.recordExists(domain) && rnsRegistry.owner(domain) == user) {
                ownedDomains++;
                if (eligibilityCriteria.requireAnyDomain) {
                    return 100; // Full score if any domain is sufficient
                }
            }
        }
        
        if (eligibilityCriteria.requiredDomains.length == 0) return 0;
        
        // Score based on percentage of required domains owned
        return (ownedDomains * 100) / eligibilityCriteria.requiredDomains.length;
    }

    // Admin functions to track on-chain activity
    function trackTransaction(address user) external onlyOwner {
        transactionCounts[user]++;
        emit TransactionTracked(user);
    }

    function trackContractInteraction(address user, address contractAddress) external onlyOwner {
        contractInteractionCounts[user]++;
        emit ContractInteractionTracked(user, contractAddress);
    }

    function batchTrackTransactions(address[] calldata users) external onlyOwner {
        for (uint i = 0; i < users.length; i++) {
            transactionCounts[users[i]]++;
            emit TransactionTracked(users[i]);
        }
    }

    function batchTrackContractInteractions(address[] calldata users, address contractAddress) external onlyOwner {
        for (uint i = 0; i < users.length; i++) {
            contractInteractionCounts[users[i]]++;
            emit ContractInteractionTracked(users[i], contractAddress);
        }
    }

    function updateEligibilityCriteria(EligibilityCriteria memory newCriteria) external onlyOwner {
        require(
            newCriteria.stakingWeight + newCriteria.activityWeight + newCriteria.rnsWeight == 100,
            "Weights must sum to 100"
        );
        eligibilityCriteria = newCriteria;
        emit CriteriaUpdated(msg.sender);
    }

    // Interface compliance functions
    function isAllowed(address user) public view returns(bool) {
        uint256 score = userScores[user];
        if (score == 0) {
            // Calculate score on-the-fly for view function
            score = _calculateScoreReadOnly(user);
        }
        return score >= eligibilityCriteria.minimumScore;
    }

    function _calculateScoreReadOnly(address user) internal view returns (uint256) {
        uint256 stakingScore = _calculateStakingScore(user);
        uint256 activityScore = _calculateActivityScore(user);
        uint256 rnsScore = _calculateRNSScore(user);
        
        return (stakingScore * eligibilityCriteria.stakingWeight +
                activityScore * eligibilityCriteria.activityWeight +
                rnsScore * eligibilityCriteria.rnsWeight) / 100;
    }

    function allowAddress(address _address) external onlyOwner {
        // For multi-criteria, we calculate and store the score
        calculateUserScore(_address);
    }

    function allowAddresses(address[] memory addresses) external onlyOwner {
        for (uint i = 0; i < addresses.length; i++) {
            calculateUserScore(addresses[i]);
        }
    }

    function disallowAddress(address _address) external onlyOwner {
        userScores[_address] = 0;
    }

    function disallowAddresses(address[] memory addresses) external onlyOwner {
        for (uint i = 0; i < addresses.length; i++) {
            userScores[addresses[i]] = 0;
        }
    }

    function setRoot(bytes32 ) external view onlyOwner {
        // Not applicable for multi-criteria airdrop, but required for interface compliance
        revert("Multi-criteria airdrop does not use Merkle trees");
    }

    // View functions
    function getAirdropInfo() public view returns(AirdropInfo memory) {
        return AirdropInfo(_airdropName, address(this), _totalAirdropAmount, _airdropAmountLeft, _claimAmount, _expirationDate, _airdropType);
    }

    function hasBalanceToClaim() public view returns(bool) {
        return _tokenContract.balanceOf(address(this), _tokenId) >= _claimAmount;
    }

    function hasBeenTotallyClaimed() public view returns(bool) {
        return _airdropAmountLeft < _claimAmount;
    }

    function hasClaimed(address _address) public view returns(bool) {
        return _addressesThatAlreadyClaimed[_address];
    }

    function hasExpired() public view returns(bool) {
        return _expirationDate < block.timestamp;
    }

    function getExpirationDate() public view returns(uint256) {
        return _expirationDate;
    }

    function getClaimAmount() public view returns(uint256) {
        return _claimAmount;
    }

    function getTotalAirdropAmount() public view returns(uint256) {
        return _totalAirdropAmount;
    }

    function getAirdropAmountLeft() public view returns(uint256) {
        return _airdropAmountLeft;
    }

    function getBalance() public view returns(uint256) {
        return _tokenContract.balanceOf(address(this), _tokenId);
    }

    function onERC1155Received(address , address , uint256 , uint256 , bytes memory) external pure returns (bytes4) {
        return bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"));
    }
}