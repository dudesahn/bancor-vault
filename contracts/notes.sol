// Liquidity pools are the LP tokens that the strategy will be holding I think? But actually probably not

// seems that to add liquidity to the liquidity protection mechanism, I need to pass the _poolAnchor address

// if you're doing this for BNT, it's:

poolAnchor = IConverterRegistry(converterRegistry).getConvertibleTokenAnchors(targetPoolToken); // for instance, LINK address would be the targetPoolToken for the LINK/BNT pool
uint256 bntAmount = bnt.balanceOf(address(this));
address bnt public = IERC20(address(0x1F573D6Fb3F13d689FF844B4cE37794d79a7FF1C));
address liquidityProtection public = 0xeead394A017b8428E2D5a976a054F303F78f3c0C; 

Start with LINK, WBTC, AAVE, SNX, wNXM, GRT, MKR

LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA

// use this to deposit into the pool with BNT
ILiquidityProtection(liquidityProtection).addLiquidity(poolAnchor, bnt, bntAmount);

to claim your rewards, you call claimBalance(startIndex, endIndex) on the pool contract, this should release any claimable BNT

// if we create the BNT vault, could we also get some space in some of the other pools? Like, stablecoins?

// questions for bancor
- Does claiming rewards reset your multiplier? 
- Is there any way around this?
- Does IL protection work the same if you deposit BNT? 30-day, 100-day, etc?
- what's the best way to view my start index and end index?
- Can yearn stake/vote with our vBNT? Does Bancor feel one way or another about this?

Asked in their dev chat:
Looking into the contracts, I have a few questions for interacting with the BNT contracts:

- Does claiming rewards via claimBalance reset your multiplier? If so, is there a way to view on-chain what your current multiplier is?
- Does the IL protection function the same way (30-day min, 100-day max) if you deposit BNT single-sided? Or does BNT get special consideration?
- What’s the best way to view the start index and end index for a position? I’m a little unclear about how this works, but it seems that it’s needed when calling claimBalance. 
- It’s my understanding that if a user deposits multiple times, these are all managed separately. How can all of these positions be viewed/tracked on the smart contract level?

- response from their CTO:
1. claimBalance isn't for claiming rewards but rather for claiming BNT withdrew from pools, so it doesn't reset the multiplier
2. you can query the multiplier per provider/pool reserve through the staking rewards contract (registry.addressOf('StakingRewards'))
3. IL protection works the same way for both TKN and BNT
4. start/end indices are just 0 based indices for locked balances - you can query the count and then pass in (0, count - 1) or you can just call claimBalance(0, 100) - it's very unlikely that you have more than a few locked balances
5. the LiquidityProtectionStore contract holds the metadata for these positions, so you can call protectedLiquidityIds(provider) to get the list and then query each one using protectedLiquidity(id)

// more questions for Bancor
- Is IL tracked on-chain? Would be great if we could determine how much a user should sacrifice (withdrawalLoss) if they withdraw early from the pool


// Bancor's v2 LM document

Bancor Liquidity Mining Version 2

High Level

Multiplier logic is forfeited in favor of a less gas intensive implementation.
A liquidity mining pool will be created, with a fixed amount of BNT used exclusively to support the liquidity mining schedule. 
The liquidity mining pool will contain 150,000,000 BNT, distributed over a 5-year period.
The token distribution begins at 1,500,000 BNT in the first week, and is progressively lowered over the course of the 5-year LM program.
Distribution is executed on a per-block basis until the LM pool supply is exhausted.
The BNT side LM rewards are distributed towards the BNT LM Staking Contract.
In order to participate in rewards users have to stake their single-sided BNT position LP tokens (NFT)
The BNT rewards will be distributed pro rata to the BNT LP tokens
The LM rewards are automatic on the BNT side of each qualifying LP token, and there is no requirement for DAO approval of LM rewards to be activated for BNT stakers. Therefore all pools in the network are actively participating in the LM program based on unified criteria.
Proposed pool qualification criteria are:
Whitelist status.
Minimum $5,000,000 depth.
These criteria can be managed over time by the DAO.
DAO approval can still be used to incentivise TKN liquidity, by offering LM rewards on the token side on an ad-hoc basis.

Bancor Catalyst Program (TKN Liquidity mining)
The voting system remains unchanged, users create proposals and vote for LM to be activated on the TKN side of whitelisted pools.
The protocol co-investment is automatically set to $2,500,000 worth of BNT (half of the $5,000,000 threshold). 
100 ppm of the liquidity mining pool size will be distributed on a weekly basis to the elected pool for a 12 week period. For example, assume 100,000,000 BNT are distributed in the first week:
100,000,000 * 0.0001 = 10,000 BNT per week.
The TKN liquidity incentives are paid from the liquidity mining pool, reducing its reserves.
In order to participate in the TKN LM, users have to stake their single-sided TKN LP (NFT) position in the TKNx LM Staking Contract (where x is the name of the token).
After 12 weeks, the emission of  BNT rewards towards TKNx LM staking Contract is stopped.
After the pool achieves liquidity the requisite $5,000,000 depth BNT LM rewards automatically trigger on the BNT side.

BNT Liquidity mining.
Liquidity mining emissions will begin at 1,500,000 BNT in the first week. 
The LM rewards will diminish over time, according to a decay function, until all 150,000,000 BNT are distributed:
Insert function here
The 5-year distribution schedule is approximated as follows:
1st year around 65M ( 40% inflation)
2nd year around 38M (25% inflation)
3rd year around  24M (16% inflation
4th year  around 15M (10% inflation)
5th year  around 10M (6% inflation)
The above number assumes an approximate 65% APY on the BNT side.
Activation of the catalyst program shortens the distribution period slightly with each run.



Stickiness Idea:

Slashing:
Direct withdrawals of BNT rewards are slashed by 50%.
Staking permits 100% of BNT rewards to be claimed, subject to a time lock-up.
After the lock is over, the user can withdraw his position as normal.
Slashed BNTs from withdrawal events can be either:
Redistributed to other BNT stakers pro rata. 
Burned.
Added back to the pool (rather, not taken from the pool). 
For example, a user has 1,000 BNT as rewards:
They restake them, forming a new protected position worth 1,000 BNT.
They withdraw the rewards. 500 BNT are returned to their wallet, and 500 BNT are left in the pool. 
We can also add AAVE like cooldown.

Pending Idea:
The rewards are increased whenever protocol is achieving a milestone such as crossing another B i TVL or 1B in daily volume in order to provide competitive rewards together with the growth of the TVL.




