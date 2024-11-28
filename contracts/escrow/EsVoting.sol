pragma solidity =0.7.6;

import "@openzeppelin/contracts:uniswap/access/Ownable.sol";

import "./EsToken.sol";


// Convenience contract to calculate voting power on Snapshot without implementing custom strategies.

contract EsVoting is Ownable {
    mapping(address => bool) public whitelist;
    bool public whitelistEnabled;
    mapping(address => address) public delegation;

    uint256 public minVotingAmount;
    bool public minVotingEnabled;
    EsToken public esTokenContract;

    constructor(
        EsToken _esTokenContract,
        bool _whitelistEnabled,
        uint256 _minVotingAmount,
        bool _minVotingEnabled
    ) {
        esTokenContract = _esTokenContract;
        whitelistEnabled = _whitelistEnabled;
        minVotingAmount = _minVotingAmount;
        minVotingEnabled = _minVotingEnabled;
    }

    function getVotingPower(
        address user
    ) external view returns (uint256 votingPower) {
        require(
            !whitelistEnabled || whitelist[user] == true,
            "Not in voting WL"
        );

        address votingUser = user;

        if (delegation[user] != address(0)) {
            votingUser = delegation[user];
        }

        uint balance = esTokenContract.balanceOf(votingUser);
        (uint allocatedAmount, ) = esTokenContract.getEsTokenBalance(
            votingUser
        );

        //view only contract
        uint sum = balance + allocatedAmount;

        votingPower = sum < minVotingAmount && minVotingEnabled ? 0 : sum;
    }

    function setWhitelist(
        address[] calldata addresses,
        bool[] calldata statuses
    ) external onlyOwner {
        require(
            addresses.length == statuses.length,
            "Input arrays must have the same length"
        );

        for (uint256 i = 0; i < addresses.length; i++) {
            whitelist[addresses[i]] = statuses[i];
        }
    }

    function setParameters(
        bool _whitelistEnabled,
        bool _minVotingEnabled,
        uint256 _minVotingAmount
    ) external onlyOwner {
        whitelistEnabled = _whitelistEnabled;
        minVotingEnabled = _minVotingEnabled;
        minVotingAmount = _minVotingAmount;
    }

    function setDelegation(address delegate) external {
        require(delegation[delegate] == address(0), "Delegate already set");

        delegation[delegate] = msg.sender;
    }

    function removeDelegation(address delegate) external {
        require(delegation[delegate] == msg.sender, "Not original delegator");

        delegation[delegate] = address(0);
    }

    function overrideDelegation(
        address delegate,
        address delegator
    ) external onlyOwner {
        delegation[delegate] = delegator;
    }
}
