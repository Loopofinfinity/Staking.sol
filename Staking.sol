// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

    contract LoopOfInfinityStaking is Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    uint256 public totalStaked; // Total amount of tokens staked in the contract
    uint256 public totalRewards; // Total amount of rewards earned by stakers
    uint256 public constant APY = 275; // Annual Percentage Yield for calculating rewards
    uint256 private constant FIXED_POINT_FACTOR = 1e18; // Factor for fixed-point arithmetic
    IERC20 public loiToken; // The ERC20 token used for staking and rewards
    uint256 public constant EMERGENCY_UNSTAKE_PENALTY = 10; // Penalty percentage for emergency unstaking
    uint256 public minGasPrice = 0; // Minimum gas price required for transactions

    enum Role { Owner, Staker }

    event Staked(address indexed staker, uint256 stakedAmount, uint256 stakingPeriod); // Emitted when tokens are staked
    event Unstaked(address indexed staker, uint256 stakedAmount, uint256 reward); // Emitted when tokens are unstaked
    event RoleAssigned(address indexed user, Role role); // Emitted when a role is assigned to a user
    event RewardsDistributed(address indexed staker, uint256 reward); // Emitted when rewards are distributed

    mapping(address => Role) public userRoles; // Mapping of user addresses to their roles
    mapping(address => mapping(address => uint256)) private stakedAmounts; // Mapping to store staked amounts
    mapping(address => mapping(address => uint256)) private stakingTimes; // Mapping to store staking times
    mapping(address => mapping(address => uint256)) private stakingPeriods; // Mapping to store staking periods
    mapping(address => mapping(address => bool)) private isActiveStaker; // Mapping to track active stakers

    modifier onlyRole(Role role) {
        require(userRoles[msg.sender] == role, "Access denied: Role required");
        _;
    }

    modifier validGasPrice() {
        require(tx.gasprice >= minGasPrice, "Gas price too low");
        _;
    }

    constructor(address _loiTokenAddress) {
        userRoles[msg.sender] = Role.Owner; // The contract deployer is the initial owner
        loiToken = IERC20(_loiTokenAddress); // Initialize the ERC20 token address for staking and rewards
    }

    // Allows the owner to set the minimum gas price required for transactions
    function setMinGasPrice(uint256 _minGasPrice) external onlyRole(Role.Owner) {
        minGasPrice = _minGasPrice;
    }

    // Checks if a given address is a staker for the caller
    function isStakerAddress(address staker) public view returns (bool) {
        return isActiveStaker[msg.sender][staker];
    }
    
   /**
 * @dev Allows a user to stake their tokens for a specific staking period and earn rewards.
 * @param stakingPeriod The duration of the staking period in months (1, 3, 6, 12).
 * @param amount The amount of tokens to be staked.
 */
   function stake(uint256 stakingPeriod, uint256 amount) external validGasPrice {
    require(stakingPeriod == 1 || stakingPeriod == 3 || stakingPeriod == 6 || stakingPeriod == 12, "Invalid staking period");
    require(amount > 0, "Amount must be greater than 0");
    require(stakedAmounts[msg.sender][msg.sender] == 0, "You already have an active stake");

    uint256 stakedAmount = amount;
    totalStaked = totalStaked.add(stakedAmount);

    // Transfer the staked tokens from the staker to the contract
    require(loiToken.transferFrom(msg.sender, address(this), stakedAmount), "Token transfer failed");

    // Record staking details for the staker
    stakedAmounts[msg.sender][msg.sender] = stakedAmount;
    stakingTimes[msg.sender][msg.sender] = block.timestamp;
    stakingPeriods[msg.sender][msg.sender] = stakingPeriod;
    isActiveStaker[msg.sender][msg.sender] = true;

    // Calculate the reward for the staker using the calculateReward function
    uint256 reward = calculateReward(msg.sender, msg.sender);
    // Update the total rewards value
    totalRewards = totalRewards.add(reward);

    // Emit the Staked event to record the staking action
    emit Staked(msg.sender, stakedAmount, stakingPeriod);
    // Emit the RewardsDistributed event to record the distributed reward
    emit RewardsDistributed(msg.sender, reward);
}
    /**
 * @dev Allows a staker to unstake their tokens after the staking period is completed, receiving their reward.
 * @param staker The address of the staker whose stake is being unstaked.
 */
    function unstake(address staker) external onlyRole(Role.Staker) validGasPrice nonReentrant {
    require(isActiveStaker[msg.sender][staker], "No active stake found");

    // Calculate the timestamp when the staking period is completed
    uint256 completionTimestamp = stakingTimes[msg.sender][staker].add(stakingPeriods[msg.sender][staker].mul(30 days));
    require(block.timestamp >= completionTimestamp, "Staking period not completed");

    // Calculate the reward for the staker using the calculateReward function
    uint256 reward = calculateReward(msg.sender, staker);
    uint256 stakedAmount = stakedAmounts[msg.sender][staker];

    // Mark the staker as inactive
    isActiveStaker[msg.sender][staker] = false;

    // Deduct the staked amount and the reward from the total values
    totalStaked = totalStaked.sub(stakedAmount);
    totalRewards = totalRewards.sub(reward);

    // Transfer the combined reward and staked amount back to the staker
       require(loiToken.transferFrom(address(this), msg.sender, reward.add(stakedAmount)), "Token transfer failed");

    // Emit the Unstaked event with the staker's information and reward
    emit Unstaked(staker, stakedAmount, reward);
    
    // Emit the RewardsDistributed event to record the distributed reward
    emit RewardsDistributed(staker, reward);
}
    /**
 * @dev Allows a staker to perform an emergency unstake with a penalty.
 * @param staker The address of the staker whose stake is being emergency unstaked.
 */
        function emergencyUnstake(address staker) external onlyRole(Role.Staker) validGasPrice nonReentrant {
        require(isActiveStaker[msg.sender][staker], "No active stake found");

        uint256 stakedAmount = stakedAmounts[msg.sender][staker];
        uint256 penalty = stakedAmount.mul(EMERGENCY_UNSTAKE_PENALTY).div(100);

        // Mark the staker as inactive
        isActiveStaker[msg.sender][staker] = false;

        // Deduct the staked amount from the total staked value
        totalStaked = totalStaked.sub(stakedAmount);

        // Transfer the remaining amount (stakedAmount - penalty) back to the staker
        require(loiToken.transferFrom(address(this), msg.sender, stakedAmount.sub(penalty)), "Token transfer failed");

    // Emit the Unstaked event with the staker's information and zero reward
       emit Unstaked(staker, stakedAmount, 0);
}
    /**
 * @dev Calculates the reward for a staker based on their staked amount, APY, and elapsed time.
 * @param user The address of the user who staked.
 * @param staker The address of the staker (can be the same as the user).
 * @return The calculated reward for the staker.
 */
    function calculateReward(address user, address staker) public view returns (uint256) {
    require(isActiveStaker[user][staker], "No active stake found");

    // Calculate the staked amount for the given user and staker
    uint256 stakedAmount = stakedAmounts[user][staker];

    // Calculate the elapsed time since staking
    uint256 elapsedTime = block.timestamp.sub(stakingTimes[user][staker]);

    // Calculate the reward numerator (stakedAmount * APY * elapsedTime * FIXED_POINT_FACTOR)
    uint256 rewardNumerator = stakedAmount.mul(APY).mul(elapsedTime).mul(FIXED_POINT_FACTOR);

    // Calculate the reward denominator (100 * 365 days * FIXED_POINT_FACTOR)
    uint256 rewardDenominator = 100 * 365 days * FIXED_POINT_FACTOR;

    // Calculate the final reward (rewardNumerator / rewardDenominator)
    uint256 reward = rewardNumerator.div(rewardDenominator);

    // Round the reward to the nearest integer
    uint256 remainder = rewardNumerator.mod(rewardDenominator);
    if (remainder.mul(2) >= rewardDenominator) {
        reward = reward.add(1);
    }

    return reward;
}
    /**
     * @dev Extends the staking period for an active stake.
     * @param additionalPeriod The additional staking period to add (1, 3, 6, or 12 months).
     */
    function extendStakingPeriod(uint256 additionalPeriod) external onlyRole(Role.Staker) validGasPrice {
    require(additionalPeriod == 1 || additionalPeriod == 3 || additionalPeriod == 6 || additionalPeriod == 12, "Invalid additional staking period");

    uint256 currentStakingPeriod = stakingPeriods[msg.sender][msg.sender]; // Using msg.sender directly
    uint256 newStakingPeriod = currentStakingPeriod.add(additionalPeriod);

    stakingPeriods[msg.sender][msg.sender] = newStakingPeriod;

    emit Staked(msg.sender, stakedAmounts[msg.sender][msg.sender], newStakingPeriod);
}
   /**
 * @dev Retrieves the details of the caller's active stake.
 * @return stakedAmount The amount of tokens staked.
 * @return stakingTime The time when staking started.
 * @return stakingPeriod The remaining staking period.
 * @return isActive Whether the stake is active.
 */
    function getStakerDetails() external view returns (uint256 stakedAmount, uint256 stakingTime, uint256 stakingPeriod, bool isActive) {
    stakedAmount = stakedAmounts[msg.sender][msg.sender];
    stakingTime = stakingTimes[msg.sender][msg.sender];
    stakingPeriod = stakingPeriods[msg.sender][msg.sender];
    isActive = isActiveStaker[msg.sender][msg.sender];
}
    /**
 * @dev Allows a staker to withdraw their earned rewards.
 */
    function withdrawRewards() external onlyRole(Role.Staker) validGasPrice nonReentrant {
    require(isActiveStaker[msg.sender][msg.sender], "No active stake found");

    uint256 reward = calculateReward(msg.sender, msg.sender);

    require(reward > 0, "No rewards to withdraw");

    stakingTimes[msg.sender][msg.sender] = block.timestamp; // Update staking time to mark the last withdrawal
    totalRewards = totalRewards.sub(reward); // Use SafeMath for subtraction

    require(loiToken.transferFrom(address(this), msg.sender, reward), "Token transfer failed");

    emit Unstaked(msg.sender, 0, reward);
}
    /**
     * @dev Retrieves the role of a given user.
     * @param user The address of the user.
     * @return The role of the user.
     */
    function getUserRole(address user) external view returns (Role) {
        return userRoles[user];
    }

    /**
 * @dev Retrieves the amount of tokens staked by the caller.
 * @return The amount of tokens staked.
 */
    function getStakedTokens() external view onlyRole(Role.Staker) returns (uint256) {
    return stakedAmounts[msg.sender][msg.sender];
}

    /**
     * @dev Retrieves the total amount of tokens staked.
     * @return The total amount of tokens staked.
     */
    function getTotalStaked() external view onlyRole(Role.Owner) returns (uint256) {
        return totalStaked;
    }

    /**
     * @dev Retrieves the number of stakers in the contract.
     * @return The number of stakers.
     */
    function getNumStakers() external view onlyRole(Role.Owner) returns (uint256) {
        return totalStaked; // Return the total number of stakers, not contract's balance
    }
}
