const {expect} = require("chai");
const hre = require("hardhat");
const ethers = hre.ethers;
const BigNumber = ethers.BigNumber;
const AddressZero = ethers.constants.AddressZero;// const ethers = require('ethers')
const { solidity, MockProvider, createFixtureLoader } = require('ethereum-waffle')
const {numberPriceToSqrtQ96, getTickAtSqrtPrice, getSqrtPriceAtTick} = require('../scripts/v3/utils/v3macros')
const {depositBunni} = require('../scripts/v3/utils/bunnimacros')
// const {solidityChai} = require('@nomiclabs/hardhat-chai-matchers')
// const { ethers} = require('ethers')
// const BigNumber = ethers.BigNumber;
const bigNumberify = ethers.BigNumber.from;

const { expandTo18Decimals, mineBlock, encodePrice, swap } = require('./utils/utilities')
const { pairFixture, tokenFixture, v3Fixture} = require('./utils/fixtures')
const exp = require("constants");
// const { AddressZero } = ethers.constants.AddressZero

const decimals = bigNumberify(10).pow(18);
const secondsInDay = 86400

const MINIMUM_LIQUIDITY = bigNumberify(10).pow(3)

// chai.use(require("@nomiclabs/hardhat-waffle").waffle.solidity);


const overrides = {
    gasLimit: 10000000
}

const feebps = 25

describe('Bunni', () => {

    let wallet, provider, other, alb, weth, usdb, bunniZapInstance, bunniHubInstance, v3Contracts

    beforeEach(async () => {
        const signers = await ethers.getSigners();
        wallet = signers[0]
        other = signers[1]
        provider = wallet.provider;
        let tokens = await tokenFixture(provider, wallet, other);
        alb = tokens.alb;
        weth = tokens.weth
        usdb = tokens.usdb
        v3Contracts = await v3Fixture(alb, weth, usdb, wallet.address)
        bunniHubInstance = v3Contracts.bunniHubInstance
        bunniZapInstance = v3Contracts.bunniZapInstance

        //add liquidity to alb weth

        let albBal = await alb.balanceOf(wallet.address)
        let wethBal = await weth.balanceOf(wallet.address)
 
         console.log("alb, weth", albBal.toString(), wethBal.toString())
         console.log("alb, weth addy", alb.address, weth.address)
 
         let isZero = (await v3Contracts.albWethPool.token0()).toLowerCase() === weth.address.toLowerCase()
 
         console.log("isZero, token0", isZero, await v3Contracts.albWethPool.token0());
         
         let sqrtPrice = (await v3Contracts.albWethPool.slot0()).sqrtPriceX96
         let sqrtPriceA = getSqrtPriceAtTick(v3Contracts.albWethBunniKey.tickLower)
         let sqrtPriceB = getSqrtPriceAtTick(v3Contracts.albWethBunniKey.tickUpper)
 
         let anchor0 = isZero ? decimals.div(2) : 0
         let anchor1 = isZero ? 0 : decimals.div(2)
 
         console.log("Depositing Bunni")
 
         await depositBunni(
             v3Contracts.bunniZapInstance,
             v3Contracts.bunniLensInstance,
             v3Contracts.albWethBunniKey,
             isZero ? weth : alb,
             isZero ? alb : weth,
             sqrtPrice,
             sqrtPriceA,
             sqrtPriceB,
             anchor0,
             anchor1,
             wallet.address,
             weth.address
         )
 
         console.log("...Done")
    })

    
    it("can't withdraw fees normally, can with skim", async () => {

        // swap(routerInstance, tokenInInstance, tokenOutInstance, amountIn, isV3, additionalParams) {

        await swap(v3Contracts.routerInstance, weth, alb, decimals.mul(1000), true, {fee: 10000, wrapETH: true})

        const key = ethers.utils.solidityKeccak256(
            ["address", "int24", "int24"],
            [v3Contracts.bunniHubInstance.address, v3Contracts.albWethBunniKey.tickLower, v3Contracts.albWethBunniKey.tickUpper]
        );

        let feeBalance = await weth.balanceOf(v3Contracts.bunniHubInstance.address)
        await v3Contracts.bunniHubInstance.compound(v3Contracts.albWethBunniKey)

        expect(await weth.balanceOf(v3Contracts.bunniHubInstance.address)).to.eq(feeBalance)

        const posInfo = await v3Contracts.albWethPool.positions(key)

        console.log("INFO", posInfo)
        
        await v3Contracts.bunniHubInstance.compoundSkim(v3Contracts.albWethBunniKey)

        expect(await weth.balanceOf(v3Contracts.bunniHubInstance.address)).to.eq(posInfo.tokensOwed1)

    });

    it("can't compoundskim as random", async () => {

        // swap(routerInstance, tokenInInstance, tokenOutInstance, amountIn, isV3, additionalParams) {

        await swap(v3Contracts.routerInstance, weth, alb, decimals.mul(1000), true, {fee: 10000, wrapETH: true})


        let eveInstance = v3Contracts.bunniHubInstance.connect(other)
        
        await expect(eveInstance.compoundSkim(v3Contracts.albWethBunniKey)).to.be.revertedWith("UNAUTHORIZED")

    });


})