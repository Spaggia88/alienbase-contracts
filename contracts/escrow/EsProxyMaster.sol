// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./interfaces/IComplexRewarder.sol";
import './interfaces/IEsTokenUsage.sol';
import './interfaces/esMaster/IEsToken.sol';
import './interfaces/esMaster/IBasedDistributorV2.sol';
import "../farm/v2/libraries/BoringERC20.sol";
import "../farm/v2/IUniswapV2Pair.sol";

//Special version of MasterChef that works with esTokens allocate()/deallocate() and proxy farming through an existing MasterChef


contract EsProxyMaster is Ownable, ReentrancyGuard, IEsTokenUsage {
    using BoringERC20 for IBoringERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 rewardLockedUp; // Reward locked up.
        uint256 nextHarvestUntil; // When can the user harvest again.
    }

    // Info of each pool.
    struct PoolInfo {
        IEsToken esToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. Token to distribute per block.
        uint256 lastRewardTimestamp; // Last timestamp of distribution.
        uint256 accTokenPerShare; // Accumulated Token per share, times 1e18. See below.
        uint256 harvestInterval; // Harvest interval in seconds
        uint256 totalLp; // Total token in Pool
        IComplexRewarder[] rewarders; // Array of rewarder contract for pools with incentives
    }

    IBoringERC20 public rewardToken;
    IBasedDistributorV2 public emissionMaster;
    uint public emissionPid;
    uint lastHarvestTimestamp;

    // Token tokens created per second
    uint256 public tokenPerSec;

    // Max harvest interval: 14 days
    uint256 public constant MAXIMUM_HARVEST_INTERVAL = 14 days;

    // Info of each pool
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    mapping(address => uint256) public esTokens;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    // The timestamp when Token mining starts.
    uint256 public startTimestamp;

    // Total locked up rewards
    uint256 public totalLockedUpRewards;

    // Total Token in Token Pools (can be multiple pools)
    uint256 public totalTokenInPools = 0;

    // The precision factor
    uint256 private immutable ACC_TOKEN_PRECISION = 1e12;

    modifier validatePoolByPid(uint256 _pid) {
        require(_pid < poolInfo.length, "Pool does not exist");
        _;
    }

    event Add(
        uint256 indexed pid,
        uint256 allocPoint,
        IEsToken indexed esToken,
        uint256 harvestInterval,
        IComplexRewarder[] indexed rewarders
    );

    event Set(
        uint256 indexed pid,
        uint256 allocPoint,
        uint256 harvestInterval,
        IComplexRewarder[] indexed rewarders
    );

    event UpdatePool(
        uint256 indexed pid,
        uint256 lastRewardTimestamp,
        uint256 lpSupply,
        uint256 accTokenPerShare
    );

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);

    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);

    event EmissionRateUpdated(
        address indexed caller,
        uint256 previousValue,
        uint256 newValue
    );

    event RewardLockedUp(
        address indexed user,
        uint256 indexed pid,
        uint256 amountLockedUp
    );

    event AllocPointsUpdated(
        address indexed caller,
        uint256 previousAmount,
        uint256 newAmount
    );
    

    constructor(
        IBoringERC20 _rewardToken
    ) {
        
        //StartBlock always many years later from contract deployment
        startTimestamp = block.timestamp + (60 * 60 * 24 * 365);

        rewardToken = _rewardToken;

        //pushes a dummy pool to fill pid 0
        poolInfo.push(
            PoolInfo({
                esToken: IEsToken(address(0)),
                allocPoint: 0,
                lastRewardTimestamp: 0,
                accTokenPerShare: 0,
                harvestInterval: 0,
                totalLp: 0,
                rewarders: new IComplexRewarder[](0)
            })
        );


    }

    // Set farming start, can call only once
    function startFarming(IBoringERC20 _dummyToken, IBasedDistributorV2 _emissionMaster, uint _emissionPid) public onlyOwner {
        require(
            block.timestamp < startTimestamp,
            "start farming: farm started already"
        );

        uint dummySupply = _dummyToken.totalSupply();
        require(_dummyToken.balanceOf(address(this)) == dummySupply, "Invalid token initialization");
        require(address(_emissionMaster) != address(0), "Invalid emission master");

        emissionMaster = _emissionMaster;
        emissionPid = _emissionPid;

        _dummyToken.approve(address(emissionMaster), dummySupply);

        emissionMaster.deposit(emissionPid, dummySupply);

        uint256 length = poolInfo.length;
        for (uint256 pid = 1; pid < length; ++pid) {
            PoolInfo storage pool = poolInfo[pid];
            pool.lastRewardTimestamp = block.timestamp;
        }

        startTimestamp = block.timestamp;
        lastHarvestTimestamp = block.timestamp;
        _updateEmissionRate();
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IEsToken _esToken,
        uint256 _harvestInterval,
        IComplexRewarder[] calldata _rewarders
    ) public onlyOwner {
        require(_rewarders.length <= 10, "add: too many rewarders");
        require(
            _harvestInterval <= MAXIMUM_HARVEST_INTERVAL,
            "add: invalid harvest interval"
        );
        require(
            Address.isContract(address(_esToken)),
            "add: LP token must be a valid contract"
        );

        require(esTokens[address(_esToken)] == 0, "Pool already exists");

        for (
            uint256 rewarderId = 0;
            rewarderId < _rewarders.length;
            ++rewarderId
        ) {
            require(
                Address.isContract(address(_rewarders[rewarderId])),
                "add: rewarder must be contract"
            );
        }

        _massUpdatePools();

        uint256 lastRewardTimestamp = block.timestamp > startTimestamp
            ? block.timestamp
            : startTimestamp;

        totalAllocPoint += _allocPoint;

        uint pid = poolInfo.length;
        esTokens[address(_esToken)] = pid;

        poolInfo.push(
            PoolInfo({
                esToken: _esToken,
                allocPoint: _allocPoint,
                lastRewardTimestamp: lastRewardTimestamp,
                accTokenPerShare: 0,
                harvestInterval: _harvestInterval,
                totalLp: 0,
                rewarders: _rewarders
            })
        );

        emit Add(
            poolInfo.length - 1,
            _allocPoint,
            _esToken,
            _harvestInterval,
            _rewarders
        );
    }

    // Update the given pool's Token allocation point and deposit fee. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint256 _harvestInterval,
        IComplexRewarder[] calldata _rewarders
    ) public onlyOwner validatePoolByPid(_pid) {
        require(_rewarders.length <= 10, "set: too many rewarders");
        require(_pid != 0, "Not authorized");

        require(
            _harvestInterval <= MAXIMUM_HARVEST_INTERVAL,
            "set: invalid harvest interval"
        );

        for (
            uint256 rewarderId = 0;
            rewarderId < _rewarders.length;
            ++rewarderId
        ) {
            require(
                Address.isContract(address(_rewarders[rewarderId])),
                "set: rewarder must be contract"
            );
        }

        _massUpdatePools();

        totalAllocPoint =
            totalAllocPoint -
            poolInfo[_pid].allocPoint +
            _allocPoint;

        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].harvestInterval = _harvestInterval;
        poolInfo[_pid].rewarders = _rewarders;

        emit Set(
            _pid,
            _allocPoint,
            _harvestInterval,
            _rewarders
        );
    }

    // View function to see pending rewards on frontend.
    function pendingTokens(uint256 _pid, address _user)
        external
        view
        validatePoolByPid(_pid)
        returns (
            address[] memory addresses,
            string[] memory symbols,
            uint256[] memory decimals,
            uint256[] memory amounts
        )
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accTokenPerShare = pool.accTokenPerShare;
        uint256 lpSupply = pool.totalLp;

        if (block.timestamp > pool.lastRewardTimestamp && lpSupply != 0) {
            uint256 multiplier = block.timestamp - pool.lastRewardTimestamp;
            
            uint256 tokenReward = (multiplier *
                tokenPerSec *
                pool.allocPoint) /
                totalAllocPoint;

            accTokenPerShare += (
                ((tokenReward * ACC_TOKEN_PRECISION) / lpSupply)
            );
        }

        uint256 pendingToken = (((user.amount * accTokenPerShare) /
            ACC_TOKEN_PRECISION) - user.rewardDebt) + user.rewardLockedUp;

        addresses = new address[](pool.rewarders.length + 1);
        symbols = new string[](pool.rewarders.length + 1);
        amounts = new uint256[](pool.rewarders.length + 1);
        decimals = new uint256[](pool.rewarders.length + 1);

        addresses[0] = address(rewardToken);
        symbols[0] = IBoringERC20(rewardToken).safeSymbol();
        decimals[0] = IBoringERC20(rewardToken).safeDecimals();
        amounts[0] = pendingToken;

        for (
            uint256 rewarderId = 0;
            rewarderId < pool.rewarders.length;
            ++rewarderId
        ) {
            addresses[rewarderId + 1] = address(
                pool.rewarders[rewarderId].rewardToken()
            );

            symbols[rewarderId + 1] = IBoringERC20(
                pool.rewarders[rewarderId].rewardToken()
            ).safeSymbol();

            decimals[rewarderId + 1] = IBoringERC20(
                pool.rewarders[rewarderId].rewardToken()
            ).safeDecimals();

            amounts[rewarderId + 1] = pool.rewarders[rewarderId].pendingTokens(
                _pid,
                _user
            );
        }
    }

    /// @notice View function to see pool rewards per sec
    function poolRewardsPerSec(uint256 _pid)
        external
        view
        validatePoolByPid(_pid)
        returns (
            address[] memory addresses,
            string[] memory symbols,
            uint256[] memory decimals,
            uint256[] memory rewardsPerSec
        )
    {
        PoolInfo storage pool = poolInfo[_pid];

        addresses = new address[](pool.rewarders.length + 1);
        symbols = new string[](pool.rewarders.length + 1);
        decimals = new uint256[](pool.rewarders.length + 1);
        rewardsPerSec = new uint256[](pool.rewarders.length + 1);

        addresses[0] = address(rewardToken);
        symbols[0] = IBoringERC20(rewardToken).safeSymbol();
        decimals[0] = IBoringERC20(rewardToken).safeDecimals();

        rewardsPerSec[0] =
            (pool.allocPoint * tokenPerSec) /
            totalAllocPoint;

        for (
            uint256 rewarderId = 0;
            rewarderId < pool.rewarders.length;
            ++rewarderId
        ) {
            addresses[rewarderId + 1] = address(
                pool.rewarders[rewarderId].rewardToken()
            );

            symbols[rewarderId + 1] = IBoringERC20(
                pool.rewarders[rewarderId].rewardToken()
            ).safeSymbol();

            decimals[rewarderId + 1] = IBoringERC20(
                pool.rewarders[rewarderId].rewardToken()
            ).safeDecimals();

            rewardsPerSec[rewarderId + 1] = pool
                .rewarders[rewarderId]
                .poolRewardsPerSec(_pid);
        }
    }

    // View function to see rewarders for a pool
    function poolRewarders(uint256 _pid)
        external
        view
        validatePoolByPid(_pid)
        returns (address[] memory rewarders)
    {
        PoolInfo storage pool = poolInfo[_pid];
        rewarders = new address[](pool.rewarders.length);
        for (
            uint256 rewarderId = 0;
            rewarderId < pool.rewarders.length;
            ++rewarderId
        ) {
            rewarders[rewarderId] = address(pool.rewarders[rewarderId]);
        }
    }

    // View function to see if user can harvest Token.
    function canHarvest(uint256 _pid, address _user)
        public
        view
        validatePoolByPid(_pid)
        returns (bool)
    {
        UserInfo storage user = userInfo[_pid][_user];
        return
            block.timestamp >= startTimestamp &&
            block.timestamp >= user.nextHarvestUntil;
    }

    // Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() external nonReentrant {
        _massUpdatePools();
    }

    // Internal method for massUpdatePools
    function _massUpdatePools() internal {
        for (uint256 pid = 1; pid < poolInfo.length; ++pid) {
            _updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) external nonReentrant {
        require(_pid != 0, "Not authorized");
        _updatePool(_pid);
    }

    // Internal method for _updatePool
    function _updatePool(uint256 _pid) internal validatePoolByPid(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        
        //harvests from parent chef and updates token per sec if necessary
        _harvestAndValidateEmissions();

        //call returns here if we did a massUpdate

        if (block.timestamp <= pool.lastRewardTimestamp) {
            return;
        }

        uint256 lpSupply = pool.totalLp;

        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardTimestamp = block.timestamp;
            return;
        }

        
        uint256 multiplier = block.timestamp - pool.lastRewardTimestamp;

        uint256 tokenReward = ((multiplier * tokenPerSec) * pool.allocPoint) /
            totalAllocPoint;

        pool.accTokenPerShare +=
            (tokenReward * ACC_TOKEN_PRECISION) /
            pool.totalLp;

        pool.lastRewardTimestamp = block.timestamp;

        emit UpdatePool(
            _pid,
            pool.lastRewardTimestamp,
            lpSupply,
            pool.accTokenPerShare
        );
    }

    // Deposit tokens for Token allocation.
    function allocate(address user, uint256 amount, bytes calldata data) external override nonReentrant {

        //only accepts calls by registered esToken contracts
        uint _pid = esTokens[msg.sender];

        require(_pid != 0, "Not authorized");

        _deposit(user, _pid, amount);
    }

    //Dedicated harvest function to avoid using allocate
    function harvest(uint256 _pid) external nonReentrant validatePoolByPid(_pid) {
        require(_pid != 0, "Not authorized");
        _deposit(msg.sender, _pid, 0);
    }



    // Deposit tokens for Token allocation.
    function _deposit(address userAddress, uint256 _pid, uint256 _amount)
        internal
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][userAddress];

        _updatePool(_pid);

        payOrLockupPendingToken(_pid, userAddress);

        if (_amount > 0) {
            
            user.amount += _amount;

            if (address(pool.esToken) == address(rewardToken)) {
                totalTokenInPools += _amount;
            }
        }
        user.rewardDebt =
            (user.amount * pool.accTokenPerShare) /
            ACC_TOKEN_PRECISION;

        for (
            uint256 rewarderId = 0;
            rewarderId < pool.rewarders.length;
            ++rewarderId
        ) {
            pool.rewarders[rewarderId].onReward(
                _pid,
                userAddress,
                user.amount
            );
        }

        if (_amount > 0) {
            pool.totalLp += _amount;
        }

        emit Deposit(userAddress, _pid, _amount);
    }

    //withdraw tokens
    function deallocate(address userAddress, uint256 _amount, bytes calldata data) external override nonReentrant {

        uint _pid = esTokens[msg.sender];
        require(_pid != 0, "Not authorized");

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][userAddress];

        require(user.amount >= _amount, "withdraw: user amount not enough");

        //cannot withdraw more than pool's balance
        require(pool.totalLp >= _amount, "withdraw: pool total not enough");

        _updatePool(_pid);

        payOrLockupPendingToken(_pid, userAddress);

        if (_amount > 0) {
            user.amount -= _amount;
            if (address(pool.esToken) == address(rewardToken)) {
                totalTokenInPools -= _amount;
            }
        }

        user.rewardDebt =
            (user.amount * pool.accTokenPerShare) /
            ACC_TOKEN_PRECISION;

        for (
            uint256 rewarderId = 0;
            rewarderId < pool.rewarders.length;
            ++rewarderId
        ) {
            try pool.rewarders[rewarderId].onReward(
                _pid,
                userAddress,
                user.amount
            ) {} catch {}
        }

        if (_amount > 0) {
            pool.totalLp -= _amount;
        }

        emit Withdraw(userAddress, _pid, _amount);
    }

    
    // Pay or lockup pending Token.
    function payOrLockupPendingToken(uint256 _pid, address userAddress) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][userAddress];

        if (user.nextHarvestUntil == 0 && block.timestamp >= startTimestamp) {
            user.nextHarvestUntil = block.timestamp + pool.harvestInterval;
        }

        uint256 pending = ((user.amount * pool.accTokenPerShare) /
            ACC_TOKEN_PRECISION) - user.rewardDebt;

        if (canHarvest(_pid, userAddress)) {
            if (pending > 0 || user.rewardLockedUp > 0) {
                uint256 pendingRewards = pending + user.rewardLockedUp;

                // reset lockup
                totalLockedUpRewards -= user.rewardLockedUp;
                user.rewardLockedUp = 0;
                user.nextHarvestUntil = block.timestamp + pool.harvestInterval;

                // send rewards
                safeTokenTransfer(userAddress, pendingRewards);
            }
        } else if (pending > 0) {
            totalLockedUpRewards += pending;
            user.rewardLockedUp += pending;
            emit RewardLockedUp(userAddress, _pid, pending);
        }
    }

    // Safe Token transfer function, just in case if rounding error causes pool do not have enough Token.
    function safeTokenTransfer(address _to, uint256 _amount) internal {
        if (rewardToken.balanceOf(address(this)) > totalTokenInPools) {
            uint256 tokenBal = rewardToken.balanceOf(address(this)) -
                totalTokenInPools;
            if (_amount >= tokenBal) {
                rewardToken.safeTransfer(_to, tokenBal);
            } else if (_amount > 0) {
                rewardToken.safeTransfer(_to, _amount);
            }
        }
    }

    function _harvestAndValidateEmissions() internal {

        (,,,,,uint harvestInterval,) = emissionMaster.poolInfo(emissionPid);

        if(block.timestamp <= lastHarvestTimestamp + harvestInterval) {
            return;
        }

        uint preBalance = rewardToken.balanceOf(address(this));

        emissionMaster.deposit(emissionPid, 0);

        uint derivedTokenPerSec = (rewardToken.balanceOf(address(this)) - preBalance) / (block.timestamp - lastHarvestTimestamp);

        // set last timestamp to avoid harvesting during massUpdate
        lastHarvestTimestamp = block.timestamp;

        if(derivedTokenPerSec != tokenPerSec) {
            _updateEmissionRate();
        }

    }

    function updateEmissionRate() public onlyOwner {
        _updateEmissionRate();
    }

    function _updateEmissionRate() internal {

        //recalculates external emission rate
        uint newTokenPerSec;
        {
            (,uint parentAllocPoint,,,,,) = emissionMaster.poolInfo(emissionPid);
            uint parentTotalAllocPoint = emissionMaster.totalAllocPoint();
            uint parentTokenPerSec = emissionMaster.albPerSec();
            
            uint teamPercent = emissionMaster.teamPercent();
            uint investorPercent = emissionMaster.investorPercent();
            uint treasuryPercent = emissionMaster.treasuryPercent();

            uint lpPercent = 1000 - teamPercent - investorPercent - treasuryPercent;
            
            newTokenPerSec = (parentTokenPerSec * parentAllocPoint / parentTotalAllocPoint) * lpPercent / 1000;

        }
        
        if(newTokenPerSec != tokenPerSec) {
            _massUpdatePools();

            emit EmissionRateUpdated(msg.sender, tokenPerSec, newTokenPerSec);

            tokenPerSec = newTokenPerSec;
        }

    }

    function updateAllocPoint(uint256 _pid, uint256 _allocPoint)
        public
        onlyOwner
    {
        require(_pid != 0, "Not authorized");
        _massUpdatePools();

        emit AllocPointsUpdated(
            msg.sender,
            poolInfo[_pid].allocPoint,
            _allocPoint
        );

        totalAllocPoint =
            totalAllocPoint -
            poolInfo[_pid].allocPoint +
            _allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    function poolTotalLp(uint256 pid) external view returns (uint256) {
        return poolInfo[pid].totalLp;
    }

    // Function to harvest many pools in a single transaction
    function harvestMany(uint256[] calldata _pids) public nonReentrant {
        require(_pids.length <= 30, "harvest many: too many pool ids");
        for (uint256 index = 0; index < _pids.length; ++index) {
            require(_pids[index] != 0, "Not authorized");
            _deposit(msg.sender, _pids[index], 0);
        }
    }

    //small imprecisions in update timing might result in reward tokens getting stuck in the contract
    //we add an admin function to retrieve them if necessary. The contract does not hold user assets in any form.
    function recoverRewardToken(uint amount) external onlyOwner {
        rewardToken.safeTransfer(owner(), amount);
    }

}
