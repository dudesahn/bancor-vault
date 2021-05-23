// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// should add a way so that pricePerShare increases over 10 days after each harvest
// maybe worth compounding rewards in the pools during the 100 days

// tend can compound rewards, could append to an array using push
// for each i in array, call withdraw

// keepers will never call harvest on these strategies, only tend to compound BNT
// can sum up profit from each tend, then add it at the end if I decide we want to stay locked up, although will depend on what they do with slashing etc
// perhaps could withdraw principal, but not do anything to rewards, and then lock back up to avoid missing bbonus

// debt ratios will be weird for this vault, but if I don't call harvest, then the strategy can't update its debtratio and it should be fine. 

// should I have a modifier in harvest that records profts and reinvests them automatically? probably not

// when I deploy the vault, make sure to adjust the lockedProfitDegration to 100 days or so

// keep 10% of funds in the vault, or in genlender? need to get BNT added to markets, then (CREAM would be a good one)

// harvest should only collect the freed up BNT, need something else to call like startStrategyWithdrawalTimer, 24 hours after that is called we can now harvest (harvest reverts if called before)
// would then also need something in the harvest call to check if there are any funds in LP (probably just have a boolean or 1/0 that we can manually set or automatically flips after previous call,
// since we're only doing 1 harvest before withdrawing everything)

    /* ========== CORE LIBRARIES ========== */

import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

    /* ========== INTERFACES ========== */

interface ILiquidityProtection {
    function addLiquidity(address poolAnchor, address reserveToken, uint256 amount) external payable returns (uint256);
    function removeLiquidity(uint256 id, uint32 portion) external;
    function claimBalance(uint256 startIndex, uint256 endIndex) external; // claiming released BNT rewards after 24 hours, maybe this should always just be 0, 50?
}

interface IStakingRewards {
    function stakeRewards(uint256 maxAmount, address poolToken) external returns (uint256, uint256);
    function claimRewards() external returns (uint256); // claim pending rewards, these are probably locked for 24 hours, I'm assuming
}


contract StrategyBancorLP is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    address public liquidityProtection = 0x42743F4d9f139bfD04680Df50Bce2d7Dd8816F90; // Bancor's liquidity protection module for LPs
    address public poolAnchor; // This is the pool we're targeting, should be set in constructor/cloning
    // for bancor's purposes, reserveToken will always be our want token
    IERC20 public constant vBNT = IERC20(address(0x48fb253446873234f2febbf9bdeaa72d9d387f94)); // this is Bancor's voting token that you receive in exchange for LPing
    uint256 public id; // this is the pool id of our pool we deposit to, will only be doing 1 deposit per strategy so shouldn't be an issue
    address public stakingRewards = 0x4B90695C2013FC60df1e168c2bCD4Fd12f5C9841; // This is the Bancor staking rewards contract

    // this controls the number of tends before we harvest
    uint256 public tendCounter = 0;
    uint256 public tendsPerHarvest = 0; // how many tends we call before we harvest. set to 0 to never call tends.
    uint256 internal harvestNow = 0; // 0 for false, 1 for true if we are mid-harvest
    uint256 public manualKeep3rHarvest = 0;
    bool public withdrawalsLocked

    /* ========== CONSTRUCTOR ========== */

    constructor(address _vault) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;
        
        // approve want token on liquidityProtection 
        want.approve(liquidityProtection, uint256(-1)); // needed for depositing BNT to LP
        vBNT.approve(liquidityProtection, uint256(-1)); // needed for retrieving BNT from LP
        poolAnchor = address(_poolAnchor) // set this from constructor/cloning
        
    }

    /* ========== CLONING ========== */

	// this is the constructor from a strategy for doing cloning. seems I should just put everything from the constructor into the initialize function, 
	// but it's only initialized in this first vault/strategy
    
    event Cloned(address indexed clone);
    
    constructor(address _vault, uint256 _poolId, address _stakingContract) public BaseStrategy(_vault) {
        _initialize(_vault, _poolId, _stakingContract, msg.sender, msg.sender, msg.sender);
    }

    /**
     * @notice
     *  Initializes the Strategy, this is called only once, when the
     *  contract is deployed.
     * @dev `_vault` should implement `VaultAPI`.
     * @param _vault The address of the Vault responsible for this Strategy.
     */
    function _initialize(
        address _vault,
        uint256 _poolId,
        address _stakingContract,
        address _strategist,
        address _rewards,
        address _keeper
    ) internal {
        require(address(want) == address(0), "Strategy already initialized");

        vault = VaultAPI(_vault);
        want = IERC20(vault.token());
        want.safeApprove(_vault, uint256(-1)); // Give Vault unlimited access (might save gas)
        strategist = _strategist;
        rewards = _rewards;
        keeper = _keeper;

        // initialize variables
        minReportDelay = 0;
        maxReportDelay = 86400;
        profitFactor = 100;
        debtThreshold = 0;
        poolId = _poolId;
        stakingContract = _stakingContract;
        vaultPerformanceFee = vault.performanceFee();

        (address lp,,,) = IMasterChef(masterchef).poolInfo(poolId);
        require(lp == address(want), "wrong pool ID");

        token0 = ISushiswapPair(address(want)).token0();
        token1 = ISushiswapPair(address(want)).token1();
        IERC20(want).safeApprove(masterchef, uint256(-1));
        IERC20(sushi).safeApprove(xsushi, uint256(-1));
        IERC20(xsushi).safeApprove(xSushiVault, uint256(-1));
        debtThreshold = 100 * 1e18;
        
        vault.approve(rewards, uint256(-1)); // Allow rewards to be pulled
    }


    function clone(address _vault, uint256 _poolId, address _stakingContract) external returns (address newStrategy) {
        newStrategy = this.clone(_vault, _poolId, _stakingContract, msg.sender, msg.sender, msg.sender);
    }

    function clone(
        address _vault,
        uint256 _poolId,
        address _stakingContract,
        address _strategist,
        address _rewards,
        address _keeper
    ) external returns (address newStrategy) {
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));

        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(clone_code, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(add(clone_code, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            newStrategy := create(0, clone_code, 0x37)
        }

        StrategySLPxSUSHI(newStrategy).initialize(_vault, _poolId, _stakingContract, _strategist, _rewards, _keeper);

        emit Cloned(newStrategy);
    }

    function initialize(
        address _vault,
        uint256 _poolId,
        address _stakingContract,
        address _strategist,
        address _rewards,
        address _keeper
    ) external virtual {
        _initialize(_vault, _poolId, _stakingContract, _strategist, _rewards, _keeper);
    }

    /* ========== VIEWS ========== */

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "StrategyBancorLP";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // TODO: Build a more accurate estimate using the value of all positions in terms of `want`
        // add up how much BNT we've put into strategies; that's it
        return want.balanceOf(address(this));
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // TODO: Do stuff here to free up any returns back into `want`
        // NOTE: Return `_profit` which is value generated by all positions, priced in `want`
        // NOTE: Should try to free up at least `_debtOutstanding` of underlying position
        
        // ultimately, we'll want to have 11 farming pools, accepting deposits for 10 days each
        // we should still allow a user to withdraw from a pool though, but will just need to calculate their IL, and dock them that amount so they don't 
        // make other users in the pools suffer
        
        
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        // TODO: Do something to invest excess `want` tokens (from the Vault) into your positions
        // NOTE: Try to adjust positions so that `_debtOutstanding` can be freed up on *next* harvest (not immediately)
        
        // deposit our liquidity to the Protected LP
        uint256 toDeposit = want.balanceOf(address(this));
        id = ILiquidityProtection(liquidityProtection).addLiquidity(poolAnchor, address(want), toDeposit);
        
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // TODO: Do stuff here to free up to `_amountNeeded` from all positions back into `want`
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`

		uint32 _portion = 1000000 // fraction of liquidity (in ppm) we need to remove
		// should I just always do 100% and then have the new pool be for withdrawals? 
        ILiquidityProtection(liquidityProtection).removeLiquidity(id, _portion)


        uint256 totalAssets = want.balanceOf(address(this));
        if (_amountNeeded > totalAssets) {
            _liquidatedAmount = totalAssets;
            _loss = _amountNeeded.sub(totalAssets);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    // NOTE: Do *not* include `want`, already included in `sweep` below
    //
    // Example:
    //
    //    function protectedTokens() internal override view returns (address[] memory) {
    //      address[] memory protected = new address[](3);
    //      protected[0] = tokenA;
    //      protected[1] = tokenB;
    //      protected[2] = tokenC;
    //      return protected;
    //    }
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}
    
    /* ========== KEEP3RS ========== */
    
    function harvestTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {
        StrategyParams memory params = vault.strategies(address(this));
        
        // have a manual toggle switch if needed since keep3rs are more efficient than manual harvest. run this at the beginning, and the end of this 
        if (manualKeep3rHarvest == 1) return true;

        // Should not trigger if Strategy is not activated
        if (params.activation == 0) return false;

        // Should not trigger if we haven't waited long enough since previous harvest
        if (block.timestamp.sub(params.lastReport) < minReportDelay)
            return false;

        // Should trigger if hasn't been called in a while
        if (block.timestamp.sub(params.lastReport) >= maxReportDelay)
            return true;

        // If some amount is owed, pay it back
        // NOTE: Since debt is based on deposits, it makes sense to guard against large
        //       changes to the value from triggering a harvest directly through user
        //       behavior. This should ensure reasonable resistance to manipulation
        //       from user-initiated withdrawals as the outstanding debt fluctuates.
        uint256 outstanding = vault.debtOutstanding();
        if (outstanding > debtThreshold) return true;

        // Check for profits and losses
        uint256 total = estimatedTotalAssets();
        // Trigger if we have a loss to report
        if (total.add(debtThreshold) < params.totalDebt) return true;

        // no need to spend the gas to harvest every time; tend is much cheaper
        if (tendCounter < tendsPerHarvest) return false;
        
        // Trigger if it makes sense for the vault to send funds idle funds from the vault to the strategy. For future, non-Curve
        // strategies, it makes more sense to make this a trigger separate from profitFactor. If I start using tend meaningfully,
        // would perhaps make sense to add in any DAI, USDC, or USDT sitting in the strategy as well since that would be added to 
        // the gauge as well. 
        uint256 profit = 0;
        if (total > params.totalDebt) profit = total.sub(params.totalDebt); // We've earned a profit!
        
        // calculate how much the call costs in dollars (converted from ETH)
        uint256 callCost = ethToDollaBill(callCostinEth);
        
        uint256 credit = vault.creditAvailable();
        return (profitFactor.mul(callCost) < credit.add(profit));
    }

    // set what will trigger keepers to call tend, which will harvest and sell CRV for optimal asset but not deposit or report profits
    function tendTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {
        // have a manual toggle switch if needed since keep3rs are more efficient than manual harvest
        if (manualKeep3rHarvest == 1) return false;

        StrategyParams memory params = vault.strategies(address(this));
        // Tend should trigger once it has been the minimum time between harvests divided by 1+tendsPerHarvest to space out tends equally
        // we multiply this number by the current tendCounter+1 to know where we are in time
        // we are assuming here that keepers will essentially call tend as soon as this is true
        if (
            block.timestamp.sub(params.lastReport) > 
            (
                minReportDelay.div(
                    (tendCounter.add(1)).mul(tendsPerHarvest.add(1))
                )
            )
        ) return true;
    }
    

    /* ========== SETTERS ========== */

    // Set the pool that we want to deposit to in case it changes; this allows the strategy to be agnostic to which pool it deposits to
    function setPoolAnchor(address _poolAnchor) external onlyAuthorized {
        poolAnchor = _poolAnchor;
    }

    
    
}
