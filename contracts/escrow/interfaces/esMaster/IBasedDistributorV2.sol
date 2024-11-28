// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

interface IBasedDistributorV2 {
    function totalAllocPoint() external view returns (uint256);

    function deposit(uint256 _pid, uint256 _amount) external;

    function poolLength() external view returns (uint256);

    function albPerSec() external view returns (uint256);

    function poolTotalLp(uint256 pid) external view returns (uint256);

    function poolInfo(uint256 pid) external view returns (address, uint256, uint256, uint256, uint16, uint256, uint256);
    
    function teamPercent() external view returns (uint256);
    function investorPercent() external view returns (uint256);
    function treasuryPercent() external view returns (uint256);
}
