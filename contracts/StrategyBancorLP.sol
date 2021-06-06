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

// PLAN
// Call tend throughout a LP pair's run to 100 days



// whenever we deploy or clone, make sure to do setLockedProfitDegradation(), set it to some amount
// also need to set maxDebtPerHarvest = 0 for these strategies once they're live
// and can set debtRatio = 0 as well for in-progress strats as well; as long as I don't harvest those strategies
// have a specific 

// make sure that PPS won't get super weird during the 24 hours when I'm waiting to claim. Need to find a way to view the strategy's locked balance waiting to be claimed

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
    function stakeRewards(uint256 maxAmount, address poolToken) external returns (uint256, uint256); // this is claiming and re-staking earned BNT rewards, this preserves your boost
    function claimRewards() external returns (uint256); // claim pending rewards, these are probably locked for 24 hours, I'm assuming
}

interface IConverterRegistry {
	function getConvertibleTokenAnchors(IERC20 _convertibleToken) external view returns (address[] memory);
}

interface IProtectionStore {
	function protectedLiquidityIds(IERC20 _convertibleToken) external view returns (address[] memory);
}

contract StrategyBancorLP is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    address public liquidityProtection = 0x853c2D147a1BD7edA8FE0f58fb3C5294dB07220e; // Bancor's liquidity protection module for LPs, can be updated by gov
    address public poolAnchor; // This is the pool we're targeting, should be set in constructor/cloning
    // for bancor's purposes, reserveToken will always be our want token
    IERC20 internal constant vBNT = IERC20(0x48fb253446873234f2febbf9bdeaa72d9d387f94); // this is Bancor's voting token that you receive in exchange for LPing
    uint256 public id; // this is the pool id of our pool we deposit to, will only be doing 1 deposit per strategy so shouldn't be an issue
    address internal constant stakingRewards = 0x4B90695C2013FC60df1e168c2bCD4Fd12f5C9841; // This is the Bancor staking rewards contract
    address internal constant converterRegistry = 0xC0205e203F423Bcd8B2a4d6f8C8A154b0Aa60F19; // bancor's registry for finding pool anchors
    address internal protectionStore = 0xf5FAB5DBD2f3bf675dE4cB76517d4767013cfB55;

    uint256 internal harvestNow = 0; // 0 for false, 1 for true if we are mid-harvest
    uint256 public manualKeep3rHarvest = 0;
    uint256 public liquidityUnlockedAt; // timestamp that our BNT is unlocked
    bool public isUnlocking = false; // this means that our BNT is currently unlocking in a 24-hour cooldown
    uint256 internal bntDeposited; // this is our starting locked rewards that we need to claim 

    /* ========== CONSTRUCTOR ========== */

    constructor(address _vault) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;
        
        // approve want token on liquidityProtection 
        want.approve(liquidityProtection, uint256(-1)); // needed for depositing BNT to LP
        vBNT.approve(liquidityProtection, uint256(-1)); // needed for retrieving BNT from LP
        poolAnchor = address(_poolAnchor); // set this from constructor/cloning
        
    }

    /* ========== VIEWS ========== */

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "StrategyBancorLP";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
    	if (isUnlocking) return bntDeposited;
        // add up how much BNT we've put into strategies; that's it. this should be able to be represented by our balance of vBNT
        // we shouldn't have any BNT sitting in the strategy but in case we do, include it
        return vBNT.balanceOf(address(this)).add(want.balanceOf(address(this)));
    }
    
    // our BNT will be claimable after a ~24-hour unlock period. 86400 seconds is one day, adding 1 hour to account for any discrepancies.
    function bntIsClaimable() public view returns (bool) {
    	if (isUnlocking) {
    		if (unlockStart.add(90000) < block.timestamp) return true;
    	}
    	return false;
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
        // make other users in the pools suffer. I think there is a way to do this based on what the bancor dude said
        // 
        
        if (bntIsClaimable()) {
        ILiquidityProtection(liquidityProtection).claimBalance(0, 100); // claim any unlocked BNT balance we have
        }
        
        // serious loss should never happen, but if it does (for instance, if Curve is hacked), let's record it accurately
        uint256 assets = estimatedTotalAssets();
        uint256 debt = vault.strategies(address(this)).totalDebt;

        // if assets are greater than debt, things are working great!
        if (assets > debt) {
            _profit = want.balanceOf(address(this));
        } else {
            // if assets are less than debt, we are in trouble
            _loss = debt.sub(assets);
            _profit = 0;
        }

        // debtOustanding will only be > 0 in the event of revoking or lowering debtRatio of a strategy
        if (_debtOutstanding > 0) {
            _debtPayment = Math.min(
                _debtOutstanding,
                want.balanceOf(address(this))
            );
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }
        if (harvestNow == 1) { // this means we are in the middle of a harvest call
    		// need to check if we are already holding vBNT, if so we shouldn't be depositing anything and should only be withdrawing
    		if (vBNT.balanceOf(address(this)) == 0) { // vBNT = 0 means we haven't deposited to a pool yet
        		// check to see if we have anything to deposit
        		if (want.balanceOf(address(this)) > 0) {
        			// deposit our liquidity to the Protected LP and store what our id is; but actually I might not need to store the id for the withdrawals
        			bntDeposited = want.balanceOf(address(this));
        			id = ILiquidityProtection(liquidityProtection).addLiquidity(poolAnchor, address(want), toDeposit);
        		}
        	}
            // since this is part of a harvest call, reset our counter to zero
            harvestNow = 0;
        }
        } else {
            // This is our tend call, which compounds our rewards for us
            IStakingRewards(stakingRewards).stakeRewards(type(uint256).max, poolAnchor);
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {

		// should I just always do 100% and then have the new pool be for withdrawals? probably yes, move it all to genLender
		// boost resets on that strategy anyway if we withdraw from it, so may as well free up the whole damn thing
		// so typically, genLender holds ~10%, when a new strategy hits 100 days it removes all funds and cycles them
		// realistically don't want to be withdrawing much of anything from highest-earning pools, so instead can just check frequently and re-arrange w/d queue based on yield
        
    	require(bntIsClaimable(), "Must wait until BNT is claimable to withdraw.");
        ILiquidityProtection(liquidityProtection).claimBalance(0, 100);
        isUnlocking = false;
        bntDeposited = 0;

        uint256 totalAssets = want.balanceOf(address(this));
        if (_amountNeeded > totalAssets) {
            _liquidatedAmount = totalAssets;
            _loss = _amountNeeded.sub(totalAssets);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        // TODO: Liquidate all positions and return the amount freed.
        return want.balanceOf(address(this));
    }

    function removeAllLiquidity() external onlyAuthorized {
        // Withdraw all liquidity, begin 24-hour cooldown to claim BNT
        uint256[] myPools = IProtectionStore(protectionStore).protectedLiquidityIds(address(this));
        if (myPools[0] > 0) {
        	for (uint256 i=0; i<myPools.length; i++) {
        		ILiquidityProtection(liquidityProtection).removeLiquidity( myPools[i], 1000000);
        	}
        	unlockStart = block.timestamp;
        	isUnlocking = true;
        }
    }

	// realistically only meant to be used in emergent situations
    function claimLiquidity() external onlyAuthorized {
    	// claim any unlocked BNT balance we have
    	require(bntIsClaimable(), "Must wait until BNT is claimable to withdraw.");
        ILiquidityProtection(liquidityProtection).claimBalance(0, 100);
        isUnlocking = false;
        bntDeposited = 0;
    }

    // prepare our want token to migrate to a new strategy if needed
    function prepareMigration(address _newStrategy) internal override {
    	require(bntIsClaimable(), "Must wait until BNT is claimable to withdraw.");
        ILiquidityProtection(liquidityProtection).claimBalance(0, 100);
        isUnlocking = false;
        bntDeposited = 0;
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}
    
    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        // TODO create an accurate price oracle
        return _amtInWei;
    }
    
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

    // don't need a tend for this strategy
    function tendTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {	return false;
    }

    

    /* ========== SETTERS ========== */

    // Set the pool that we want to deposit to in case it changes; this allows the strategy to be agnostic to which pool it deposits to
    function setPoolAnchor(address _poolAnchor) external onlyAuthorized {
        poolAnchor = _poolAnchor;
    }
    
    // Set the liquidity protection that we want to deposit to in case it changes; this allows the strategy to be agnostic to which pool it deposits to
    function setliquidityProtection(address _liquidityProtection) external onlyGov {
        liquidityProtection = _liquidityProtection;
    }  
    
    

    /* ========== CLONING ========== */

	// this is the constructor from a strategy for doing cloning. seems I should just put everything from the constructor into the initialize function, 
	// but it's only initialized in this first vault/strategy
    
    event Cloned(address indexed clone);
    
    constructor(address _vault, address _targetPoolToken) public BaseStrategy(_vault) {
        _initialize(_vault, _targetPoolToken, msg.sender, msg.sender, msg.sender);
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
        address _targetPoolToken,
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
        
        
        // here's the stuff I know I need to do for Bancor
        poolAnchor = IConverterRegistry(converterRegistry).getConvertibleTokenAnchors(_targetPoolToken); // for instance, LINK address would be the targetPoolToken for the LINK/BNT pool
        
        
        
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
    
}
