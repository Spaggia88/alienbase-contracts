// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

import "@openzeppelin/contracts:uniswap/access/Ownable.sol";
import "@openzeppelin/contracts:uniswap/math/SafeMath.sol";
import "@openzeppelin/contracts:uniswap/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts:uniswap/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts:uniswap/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts:uniswap/utils/EnumerableSet.sol";
import "@openzeppelin/contracts:uniswap/token/ERC20/IERC20.sol";

import "./interfaces/tokens/IEsToken.sol";
import "./interfaces/IEsTokenUsage.sol";


/*
 * esToken is a generalized implementation of Camelot xGrail
 * It's non-transferable, except from/to whitelisted addresses
 * It can be converted back to Token through a vesting process
 * This contract is made to receive esToken deposits from users in order to allocate them to Usages (plugins) contracts
 * * Changes from original include:
 * - Removed deallocationFee
 * - Triggered redemptions have a time limit to avoid perpetual options to withdraw immediately while still earning yield
 * - Users can instantly redeem slightly more than 1% of their position every 12 hours
 * - Excess of underlyingTokens is sent to treasury instead of being burned
 * - Fixed bug in original contract where owner could set an invalid dividendsAddress and brick user funds
 */


contract EsToken is Ownable, ReentrancyGuard, ERC20, IEsToken {
  using Address for address;
  using SafeMath for uint256;
  using EnumerableSet for EnumerableSet.AddressSet;
  using SafeERC20 for IERC20;

  struct EsTokenBalance {
    uint256 allocatedAmount; // Amount of esToken allocated to a Usage
    uint256 redeemingAmount; // Total amount of esToken currently being redeemed
  }

  struct RedeemInfo {
    uint256 tokenAmount; // Token amount to receive when vesting has ended
    uint256 esTokenAmount; // esToken amount to redeem
    uint256 endTime;
    IEsTokenUsage dividendsAddress;
    uint256 dividendsAllocation; // Share of redeeming esToken to allocate to the Dividends Usage contract
  }

  IERC20 public immutable underlyingToken; // Token token to convert to/from
  IEsTokenUsage public dividendsAddress; // Farm/dividends contract

  EnumerableSet.AddressSet private _transferWhitelist; // addresses allowed to send/receive esToken

  mapping(address => mapping(address => uint256)) public usageApprovals; // Usage approvals to allocate esToken
  mapping(address => mapping(address => uint256)) public override usageAllocations; // Active esToken allocations to usages

  uint256 public constant MAX_FIXED_RATIO = 100; // 100%

  // Redeeming min/max settings
  uint256 public minRedeemRatio = 50; // 1:0.5
  uint256 public maxRedeemRatio = 100; // 1:1
  uint256 public minRedeemDuration = 15 days;
  uint256 public maxRedeemDuration = 30 days;
  // Adjusted dividends rewards for redeeming esToken
  uint256 public redeemDividendsAdjustment; // 0% at construction to avoid bricking calls
  
  uint256 public freeRedeemPercentage = 100; //1%
  //owner-defined minimum redemption value to avoid requiring infinite mini-redemptions to exit a position
  uint256 public minFreeRedeem;
  uint256 public freeRedeemCooldown = 12 hours;
  uint256 public redemptionGracePeriod = 7 days;

  mapping(address => EsTokenBalance) public esTokenBalances; // User's esToken balances
  mapping(address => RedeemInfo[]) public userRedeems; // User's redeeming instances
  mapping(address => uint256) public freeRedeemAllowances;

  address public treasuryAddress;


  constructor(IERC20 _underlyingToken, string memory name, string memory symbol, address _treasuryAddress) ERC20(name, symbol) {
    underlyingToken = _underlyingToken;
    _transferWhitelist.add(address(this));

    require(_treasuryAddress != address(0), "Invalid treasury address");

    treasuryAddress = _treasuryAddress;
  }

  /********************************************/
  /****************** EVENTS ******************/
  /********************************************/

  event ApproveUsage(address indexed userAddress, address indexed usageAddress, uint256 amount);
  event Convert(address indexed from, address to, uint256 amount);
  event UpdateRedeemSettings(
    uint256 minRedeemRatio,
    uint256 maxRedeemRatio,
    uint256 minRedeemDuration,
    uint256 maxRedeemDuration,
    uint256 redeemDividendsAdjustment,
    uint256 freeRedeemPercentage,
    uint256 minFreeRedeem,
    uint256 freeRedeemCooldown,
    uint256 redemptionGracePeriod
  );
  event UpdateDividendsAddress(address previousDividendsAddress, address newDividendsAddress);
  event SetTransferWhitelist(address account, bool add);
  event Redeem(address indexed userAddress, uint256 esTokenAmount, uint256 tokenAmount, uint256 duration);
  event FinalizeRedeem(address indexed userAddress, uint256 esTokenAmount, uint256 tokenAmount);
  event CancelRedeem(address indexed userAddress, uint256 esTokenAmount);
  event UpdateRedeemDividendsAddress(address indexed userAddress, uint256 redeemIndex, address previousDividendsAddress, address newDividendsAddress);
  event UpdateTreasuryAddress(address indexed newTreasuryAddress, address indexed oldTreasuryAddress);
  event Allocate(address indexed userAddress, address indexed usageAddress, uint256 amount);
  event Deallocate(address indexed userAddress, address indexed usageAddress, uint256 amount);

  /***********************************************/
  /****************** MODIFIERS ******************/
  /***********************************************/

  /*
   * @dev Check if a redeem entry exists
   */
  modifier validateRedeem(address userAddress, uint256 redeemIndex) {
    require(redeemIndex < userRedeems[userAddress].length, "validateRedeem: redeem entry does not exist");
    _;
  }

  /**************************************************/
  /****************** PUBLIC VIEWS ******************/
  /**************************************************/

  /*
   * @dev Returns user's esToken balances
   */
  function getEsTokenBalance(address userAddress) external view returns (uint256 allocatedAmount, uint256 redeemingAmount) {
    EsTokenBalance storage balance = esTokenBalances[userAddress];
    return (balance.allocatedAmount, balance.redeemingAmount);
  }

  /*
   * @dev returns redeemable Token for "amount" of esToken vested for "duration" seconds
   */
  function getTokenByVestingDuration(uint256 amount, uint256 duration) public view returns (uint256) {
    if(duration == 0) {
        return amount; //special case for small withdrawals
    }

    if(duration < minRedeemDuration) {
      return 0;
    }

    // capped to maxRedeemDuration
    if (duration > maxRedeemDuration) {
      return amount.mul(maxRedeemRatio).div(100);
    }

    uint256 ratio = minRedeemRatio.add(
      (duration.sub(minRedeemDuration)).mul(maxRedeemRatio.sub(minRedeemRatio))
      .div(maxRedeemDuration.sub(minRedeemDuration))
    );

    return amount.mul(ratio).div(100);
  }

  /**
   * @dev returns quantity of "userAddress" pending redeems
   */
  function getUserRedeemsLength(address userAddress) external view returns (uint256) {
    return userRedeems[userAddress].length;
  }

  /**
   * @dev returns "userAddress" info for a pending redeem identified by "redeemIndex"
   */
  function getUserRedeem(address userAddress, uint256 redeemIndex) external view validateRedeem(userAddress, redeemIndex) returns (uint256 tokenAmount, uint256 esTokenAmount, uint256 endTime, address dividendsContract, uint256 dividendsAllocation) {
    RedeemInfo storage _redeem = userRedeems[userAddress][redeemIndex];
    return (_redeem.tokenAmount, _redeem.esTokenAmount, _redeem.endTime, address(_redeem.dividendsAddress), _redeem.dividendsAllocation);
  }

  /**
   * @dev returns approved esToken to allocate from "userAddress" to "usageAddress"
   */
  function getUsageApproval(address userAddress, address usageAddress) external view returns (uint256) {
    return usageApprovals[userAddress][usageAddress];
  }

  /**
   * @dev returns allocated esToken from "userAddress" to "usageAddress"
   */
  function getUsageAllocation(address userAddress, address usageAddress) external view returns (uint256) {
    return usageAllocations[userAddress][usageAddress];
  }

  /**
   * @dev returns length of transferWhitelist array
   */
  function transferWhitelistLength() external view returns (uint256) {
    return _transferWhitelist.length();
  }

  /**
   * @dev returns transferWhitelist array item's address for "index"
   */
  function transferWhitelist(uint256 index) external view returns (address) {
    return _transferWhitelist.at(index);
  }

  /**
   * @dev returns if "account" is allowed to send/receive esToken
   */
  function isTransferWhitelisted(address account) external override view returns (bool) {
    return _transferWhitelist.contains(account);
  }

  /*******************************************************/
  /****************** OWNABLE FUNCTIONS ******************/
  /*******************************************************/

  /**
   * @dev Updates all redeem ratios and durations
   *
   * Must only be called by owner
   */
  function updateRedeemSettings(
    uint256 minRedeemRatio_,
    uint256 maxRedeemRatio_,
    uint256 minRedeemDuration_,
    uint256 maxRedeemDuration_,
    uint256 redeemDividendsAdjustment_,
    uint256 freeRedeemPercentage_,
    uint256 minFreeRedeem_,
    uint256 freeRedeemCooldown_,
    uint256 redemptionGracePeriod_
    ) external onlyOwner {
    require(minRedeemRatio_ <= maxRedeemRatio_, "updateRedeemSettings: wrong ratio values");
    require(minRedeemDuration_ < maxRedeemDuration_, "updateRedeemSettings: wrong duration values");
    // should never exceed 100%
    require(maxRedeemRatio_ <= MAX_FIXED_RATIO && redeemDividendsAdjustment_ <= MAX_FIXED_RATIO, "updateRedeemSettings: wrong ratio values");
    if(redeemDividendsAdjustment_ > 0) {
      require(address(dividendsAddress) != address(0), "updateRedeemSettings: dividendsAddress not initialized");
      //tests an allocation to ensure the target contract responds to specification
      dividendsAddress.allocate(address(this), 0, new bytes(0));
      dividendsAddress.deallocate(address(this), 0, new bytes(0));
    }

    require(freeRedeemPercentage_ >= 0 && freeRedeemPercentage_ <= 10000, "updateRedeemSettings: invalid redeem percentage");
    
    minRedeemRatio = minRedeemRatio_;
    maxRedeemRatio = maxRedeemRatio_;
    minRedeemDuration = minRedeemDuration_;
    maxRedeemDuration = maxRedeemDuration_;
    redeemDividendsAdjustment = redeemDividendsAdjustment_;

    freeRedeemPercentage = freeRedeemPercentage_;
    minFreeRedeem = minFreeRedeem_;
    freeRedeemCooldown = freeRedeemCooldown_;
    redemptionGracePeriod = redemptionGracePeriod_;
    

    emit UpdateRedeemSettings(
        minRedeemRatio_,
        maxRedeemRatio_,
        minRedeemDuration_,
        maxRedeemDuration_,
        redeemDividendsAdjustment_,
        freeRedeemPercentage_,
        minFreeRedeem_,
        freeRedeemCooldown_,
        redemptionGracePeriod_
    );
  }

  function updateTreasuryAddress(address _newTreasuryAddress) external onlyOwner {
    require(_newTreasuryAddress != address(0), "Invalid treasury address");
    emit UpdateTreasuryAddress(_newTreasuryAddress, treasuryAddress);
    treasuryAddress = _newTreasuryAddress;
  }

  /**
   * @dev Updates dividends contract address
   *
   * Must only be called by owner
   */
  function updateDividendsAddress(IEsTokenUsage dividendsAddress_) external onlyOwner {
    // if set to 0, also set divs earnings while redeeming to 0
    if(address(dividendsAddress_) == address(0)) {
      redeemDividendsAdjustment = 0;
    } else {
      //tests an allocation to ensure the target contract responds to specification
      dividendsAddress_.allocate(address(this), 0, new bytes(0));
      dividendsAddress_.deallocate(address(this), 0, new bytes(0));
    }

    emit UpdateDividendsAddress(address(dividendsAddress), address(dividendsAddress_));
    dividendsAddress = dividendsAddress_;
  }


  /**
   * @dev Adds or removes addresses from the transferWhitelist
   */
  function updateTransferWhitelist(address account, bool add) external onlyOwner {
    require(account != address(this), "updateTransferWhitelist: Cannot remove esToken from whitelist");

    if(add) _transferWhitelist.add(account);
    else _transferWhitelist.remove(account);

    emit SetTransferWhitelist(account, add);
  }

  /*****************************************************************/
  /******************  EXTERNAL PUBLIC FUNCTIONS  ******************/
  /*****************************************************************/

  /**
   * @dev Approves "usage" address to get allocations up to "amount" of esToken from msg.sender
   */
  function approveUsage(IEsTokenUsage usage, uint256 amount) external nonReentrant {
    require(address(usage) != address(0), "approveUsage: approve to the zero address");

    usageApprovals[msg.sender][address(usage)] = amount;
    emit ApproveUsage(msg.sender, address(usage), amount);
  }

  /**
   * @dev Convert caller's "amount" of Token to esToken
   */
  function convert(uint256 amount) external nonReentrant {
    _convert(amount, msg.sender);
  }

  /**
   * @dev Convert caller's "amount" of Token to esToken to "to" address
   */
  function convertTo(uint256 amount, address to) external override nonReentrant {
    require(address(msg.sender).isContract(), "convertTo: not allowed");
    _convert(amount, to);
  }

  /**
   * @dev Initiates redeem process (esToken to Token)
   *
   * Handles dividends' compensation allocation during the vesting process if needed
   */
  function redeem(uint256 esTokenAmount, uint256 duration) external nonReentrant {
    require(esTokenAmount > 0, "redeem: esTokenAmount cannot be null");

    EsTokenBalance storage balance = esTokenBalances[msg.sender];
    {
        //instant free redeem check
        //use total balance for percentages
        //call reverts if user tries to redeem more than the free balance
        uint256 lastUserRedemption = freeRedeemAllowances[msg.sender];
        uint256 userTotalBalance = super.balanceOf(msg.sender).add(balance.allocatedAmount).add(balance.redeemingAmount);


        uint256 freeAllowance = (userTotalBalance.mul(freeRedeemPercentage) / 10000).add(minFreeRedeem);
        
        if( duration != 0 
        || _currentBlockTimestamp() < lastUserRedemption + freeRedeemCooldown 
        || esTokenAmount > freeAllowance) {
            require(duration >= minRedeemDuration, "redeem: invalid request");
        }
    }    

    _transfer(msg.sender, address(this), esTokenAmount);

    // get corresponding Token amount
    uint256 tokenAmount = getTokenByVestingDuration(esTokenAmount, duration);
    emit Redeem(msg.sender, esTokenAmount, tokenAmount, duration);

    // if redeeming is not immediate, go through vesting process
    if(duration > 0) {
        // add to SBT total
        balance.redeemingAmount = balance.redeemingAmount.add(esTokenAmount);

        // handle dividends during the vesting process
        uint256 dividendsAllocation = esTokenAmount.mul(redeemDividendsAdjustment).div(100);
        // only if compensation is active
        if(dividendsAllocation > 0) {
            // allocate to dividends
            dividendsAddress.allocate(msg.sender, dividendsAllocation, new bytes(0));
        }

        // add redeeming entry
        userRedeems[msg.sender].push(RedeemInfo(tokenAmount, esTokenAmount, _currentBlockTimestamp().add(duration), dividendsAddress, dividendsAllocation));
    } else {
        //updates timestamp for cooldown
        freeRedeemAllowances[msg.sender] = _currentBlockTimestamp();
        // immediately redeem for underlyingToken
        _finalizeRedeem(msg.sender, esTokenAmount, tokenAmount);
    }
  }

  /**
   * @dev Finalizes redeem process when vesting duration has been reached
   *
   * Can only be called by the redeem entry owner
   */
  function finalizeRedeem(uint256 redeemIndex) external nonReentrant validateRedeem(msg.sender, redeemIndex) {
    EsTokenBalance storage balance = esTokenBalances[msg.sender];
    RedeemInfo storage _redeem = userRedeems[msg.sender][redeemIndex];
    require(_currentBlockTimestamp() >= _redeem.endTime, "finalizeRedeem: vesting duration has not ended yet");
    //Introduce a limit to redemptions to avoid giving free options. Users must cancel and restart redemption
    require(_currentBlockTimestamp() <= _redeem.endTime + redemptionGracePeriod, "finalizeRedeem: grace period expired");

    // remove from SBT total
    balance.redeemingAmount = balance.redeemingAmount.sub(_redeem.esTokenAmount);
    _finalizeRedeem(msg.sender, _redeem.esTokenAmount, _redeem.tokenAmount);

    // handle dividends compensation if any was active
    if(_redeem.dividendsAllocation > 0) {
      // deallocate from dividends
      IEsTokenUsage(_redeem.dividendsAddress).deallocate(msg.sender, _redeem.dividendsAllocation, new bytes(0));
    }

    // remove redeem entry
    _deleteRedeemEntry(redeemIndex);
  }

  /**
   * @dev Updates dividends address for an existing active redeeming process
   *
   * Can only be called by the involved user
   * Should only be used if dividends contract was to be migrated
   */
  function updateRedeemDividendsAddress(uint256 redeemIndex) external nonReentrant validateRedeem(msg.sender, redeemIndex) {
    RedeemInfo storage _redeem = userRedeems[msg.sender][redeemIndex];

    // only if the active dividends contract is not the same anymore
    if(dividendsAddress != _redeem.dividendsAddress && address(dividendsAddress) != address(0)) {
      if(_redeem.dividendsAllocation > 0) {
        // deallocate from old dividends contract
        _redeem.dividendsAddress.deallocate(msg.sender, _redeem.dividendsAllocation, new bytes(0));
        // allocate to new used dividends contract
        dividendsAddress.allocate(msg.sender, _redeem.dividendsAllocation, new bytes(0));
      }

      emit UpdateRedeemDividendsAddress(msg.sender, redeemIndex, address(_redeem.dividendsAddress), address(dividendsAddress));
      _redeem.dividendsAddress = dividendsAddress;
    }
  }

  /**
   * @dev Cancels an ongoing redeem entry
   *
   * Can only be called by its owner
   */
  function cancelRedeem(uint256 redeemIndex) external nonReentrant validateRedeem(msg.sender, redeemIndex) {
    EsTokenBalance storage balance = esTokenBalances[msg.sender];
    RedeemInfo storage _redeem = userRedeems[msg.sender][redeemIndex];

    // make redeeming esToken available again
    balance.redeemingAmount = balance.redeemingAmount.sub(_redeem.esTokenAmount);
    _transfer(address(this), msg.sender, _redeem.esTokenAmount);

    // handle dividends compensation if any was active
    if(_redeem.dividendsAllocation > 0) {
      // deallocate from dividends
      IEsTokenUsage(_redeem.dividendsAddress).deallocate(msg.sender, _redeem.dividendsAllocation, new bytes(0));
    }

    emit CancelRedeem(msg.sender, _redeem.esTokenAmount);

    // remove redeem entry
    _deleteRedeemEntry(redeemIndex);
  }


  /**
   * @dev Allocates caller's "amount" of available esToken to "usageAddress" contract
   *
   * args specific to usage contract must be passed into "usageData"
   */
  function allocate(address usageAddress, uint256 amount, bytes calldata usageData) external nonReentrant {
    _allocate(msg.sender, usageAddress, amount);

    // allocates esToken to usageContract
    IEsTokenUsage(usageAddress).allocate(msg.sender, amount, usageData);
  }

  /**
   * @dev Allocates "amount" of available esToken from "userAddress" to caller (ie usage contract)
   *
   * Caller must have an allocation approval for the required esToken from "userAddress"
   */
  function allocateFromUsage(address userAddress, uint256 amount) external override nonReentrant {
    _allocate(userAddress, msg.sender, amount);
  }

  /**
   * @dev Deallocates caller's "amount" of available esToken from "usageAddress" contract
   *
   * args specific to usage contract must be passed into "usageData"
   */
  function deallocate(address usageAddress, uint256 amount, bytes calldata usageData) external nonReentrant {
    _deallocate(msg.sender, usageAddress, amount);

    // deallocate esToken into usageContract
    IEsTokenUsage(usageAddress).deallocate(msg.sender, amount, usageData);
  }

  /**
   * @dev Deallocates "amount" of allocated esToken belonging to "userAddress" from caller (ie usage contract)
   *
   * Caller can only deallocate esToken from itself
   */
  function deallocateFromUsage(address userAddress, uint256 amount) external override nonReentrant {
    _deallocate(userAddress, msg.sender, amount);
  }

  /********************************************************/
  /****************** INTERNAL FUNCTIONS ******************/
  /********************************************************/

  /**
   * @dev Convert caller's "amount" of Token into esToken to "to"
   */
  function _convert(uint256 amount, address to) internal {
    require(amount != 0, "convert: amount cannot be null");

    // mint new esToken
    _mint(to, amount);

    emit Convert(msg.sender, to, amount);
    underlyingToken.safeTransferFrom(msg.sender, address(this), amount);
  }

  /**
   * @dev Finalizes the redeeming process for "userAddress" by transferring him "tokenAmount" and removing "esTokenAmount" from supply
   *
   * Any vesting check should be ran before calling this
   * Token excess is automatically burnt
   */
  function _finalizeRedeem(address userAddress, uint256 esTokenAmount, uint256 tokenAmount) internal {
    uint256 tokenExcess = esTokenAmount.sub(tokenAmount);

    // sends due tokens
    underlyingToken.safeTransfer(userAddress, tokenAmount);

    // sends excess tokens to treasury
    if(tokenExcess > 0) {
      underlyingToken.safeTransfer(treasuryAddress, tokenExcess);
    }
    _burn(address(this), esTokenAmount);

    emit FinalizeRedeem(userAddress, esTokenAmount, tokenAmount);
  }

  /**
   * @dev Allocates "userAddress" user's "amount" of available esToken to "usageAddress" contract
   *
   */
  function _allocate(address userAddress, address usageAddress, uint256 amount) internal {
    require(amount > 0, "allocate: amount cannot be null");

    EsTokenBalance storage balance = esTokenBalances[userAddress];

    // approval checks if allocation request amount has been approved by userAddress to be allocated to this usageAddress
    uint256 approvedEsToken = usageApprovals[userAddress][usageAddress];
    require(approvedEsToken >= amount, "allocate: non authorized amount");

    // remove allocated amount from usage's approved amount
    usageApprovals[userAddress][usageAddress] = approvedEsToken.sub(amount);

    // update usage's allocatedAmount for userAddress
    usageAllocations[userAddress][usageAddress] = usageAllocations[userAddress][usageAddress].add(amount);

    // adjust user's esToken balances
    balance.allocatedAmount = balance.allocatedAmount.add(amount);
    _transfer(userAddress, address(this), amount);

    emit Allocate(userAddress, usageAddress, amount);
  }

  /**
   * @dev Deallocates "amount" of available esToken to "usageAddress" contract
   *
   * args specific to usage contract must be passed into "usageData"
   */
  function _deallocate(address userAddress, address usageAddress, uint256 amount) internal {
    require(amount > 0, "deallocate: amount cannot be null");

    // check if there is enough allocated esToken to this usage to deallocate
    uint256 allocatedAmount = usageAllocations[userAddress][usageAddress];
    require(allocatedAmount >= amount, "deallocate: non authorized amount");

    // remove deallocated amount from usage's allocation
    usageAllocations[userAddress][usageAddress] = allocatedAmount.sub(amount);

    // adjust user's esToken balances
    EsTokenBalance storage balance = esTokenBalances[userAddress];
    balance.allocatedAmount = balance.allocatedAmount.sub(amount);
    _transfer(address(this), userAddress, amount);
    
    emit Deallocate(userAddress, usageAddress, amount);
  }

  function _deleteRedeemEntry(uint256 index) internal {
    userRedeems[msg.sender][index] = userRedeems[msg.sender][userRedeems[msg.sender].length - 1];
    userRedeems[msg.sender].pop();
  }

  /**
   * @dev Hook override to forbid transfers except from whitelisted addresses and minting
   */
  function _beforeTokenTransfer(address from, address to, uint256 /*amount*/) internal view override {
    require(from == address(0) || _transferWhitelist.contains(from) || _transferWhitelist.contains(to), "transfer: not allowed");
  }

  /**
   * @dev Utility function to get the current block timestamp
   */
  function _currentBlockTimestamp() internal view virtual returns (uint256) {
    /* solhint-disable not-rely-on-time */
    return block.timestamp;
  }

}