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
