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
