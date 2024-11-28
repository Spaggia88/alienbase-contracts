// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6;

import "@openzeppelin/contracts-5/token/ERC20/IERC20.sol";

import "./IEsTokenUsage.sol";


interface IEsToken is IERC20 {
  function usageAllocations(address userAddress, address usageAddress) external view returns (uint256 allocation);

  function allocateFromUsage(address userAddress, uint256 amount) external;
  function convertTo(uint256 amount, address to) external;
  function deallocateFromUsage(address userAddress, uint256 amount) external;

  function isTransferWhitelisted(address account) external view returns (bool);

  function allocate(address usageAddress, uint256 amount, bytes calldata usageData) external;
  function deallocate(address usageAddress, uint256 amount, bytes calldata usageData) external;
  function approveUsage(IEsTokenUsage usage, uint256 amount) external;
}
