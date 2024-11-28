const {expect} = require("chai");
const { ethers } = require("hardhat");
const { BigNumber } = ethers;
const { AddressZero } = ethers.constants;// const ethers = require('ethers')
const { solidity, MockProvider, createFixtureLoader } = require('ethereum-waffle')
// const {solidityChai} = require('@nomiclabs/hardhat-chai-matchers')
// const { ethers} = require('ethers')
// const BigNumber = ethers.BigNumber;
const bigNumberify = ethers.BigNumber.from;

const { expandTo18Decimals, mineBlock, encodePrice } = require('./utils/utilities')
const { pairFixture, esTokenFixture, tokenFixture, esProxyMasterFixture, distributorFixture} = require('./utils/fixtures')
const exp = require("constants");
const {over} = require("lodash/util");
// const { AddressZero } = ethers.constants.AddressZero

const decimals = bigNumberify(10).pow(18);
const secondsInDay = 86400

const MINIMUM_LIQUIDITY = bigNumberify(10).pow(3)

// chai.use(require("@nomiclabs/hardhat-waffle").waffle.solidity);


const overrides = {
    gasLimit: 10000000
}

const feebps = 25

describe('esToken', () => {

    let wallet, provider, other, alb, tokenA, tokenB, esToken, esMaster, masterChef, masterController;

    beforeEach(async () => {
        [wallet, other] = await ethers.getSigners();
        provider = wallet.provider;
        // alb = await tokenFixture(provider, wallet, other);
        console.log("Initializing Distributor")
        let distr = await distributorFixture(wallet, other)
        alb = distr.alb;
        masterChef = distr.masterChef;
        masterController = distr.masterController;
        console.log("Initialized Distributo")
        esToken = await esTokenFixture(alb, wallet.address);
        console.log("Initialized Token")
        esMaster = await esProxyMasterFixture(alb, masterChef, masterController, wallet)
        console.log("Initialized Master")
    })

    //tests of changes include:
    // - can mint, can change all parameters including new ones and only if owner
    // - can redeem normally for full duration or slashed for half with shorter duration
    // - can insta redeem small amount, can't redeem large amounts, can't redeem larger than balance,
    // - can set dividendsAddress if the esMaster is set up correctly, can't otherwise 

    it('basics: mint, all parameters can change, access control', async () => {
        
        await alb.approve(esToken.address, decimals.pow(2));

        console.log("alb, esToken, wallet", alb.address, esToken.address, wallet.address)

        await esToken.convert(decimals.mul(10000));

        await expect(await esToken.balanceOf(wallet.address)).to.eq(decimals.mul(10000));
        
        // function updateRedeemSettings(
        //     uint256 minRedeemRatio_,
        //     uint256 maxRedeemRatio_,
        //     uint256 minRedeemDuration_,
        //     uint256 maxRedeemDuration_,
        //     uint256 redeemDividendsAdjustment_,
        //     uint256 freeRedeemPercentage_,
        //     uint256 minFreeRedeem_,
        //     uint256 freeRedeemCooldown_,
        //     uint256 redemptionGracePeriod_
        //     )
        
        const oldMinRedeemRatio = await esToken.minRedeemRatio()
        const oldMaxRedeemRatio = await esToken.maxRedeemRatio()
        const oldMinRedeemDuration = await esToken.minRedeemDuration()
        const oldMaxRedeemDuration = await esToken.maxRedeemDuration()
        const oldFreeRedeemPercentage = await esToken.freeRedeemPercentage()
        const oldMinFreeRedeem = await esToken.minFreeRedeem()
        const oldfreeRedeemCooldown = await esToken.freeRedeemCooldown()
        const oldRedemptionGracePeriod = await esToken.redemptionGracePeriod()
    
        const newMinRedeemRatio = 80
        const newMaxRedeemRatio = 90
        const newMinRedeemDuration = 2 * secondsInDay
        const newMaxRedeemDuration = 4 * secondsInDay
        const newFreeRedeemPercentage = 500
        const newMinFreeRedeem = decimals.mul(50)
        const newfreeRedeemCooldown = secondsInDay/4
        const newRedemptionGracePeriod = 3 * secondsInDay


        await esToken.updateRedeemSettings(
            newMinRedeemRatio,
            newMaxRedeemRatio,
            newMinRedeemDuration,
            newMaxRedeemDuration,
            0, //redeemDividends
            newFreeRedeemPercentage,
            newMinFreeRedeem,
            newfreeRedeemCooldown,
            newRedemptionGracePeriod
        )

        const finalMinRedeemRatio = await esToken.minRedeemRatio()
        const finalMaxRedeemRatio = await esToken.maxRedeemRatio()
        const finalMinRedeemDuration = await esToken.minRedeemDuration()
        const finalMaxRedeemDuration = await esToken.maxRedeemDuration()
        const finalFreeRedeemPercentage = await esToken.freeRedeemPercentage()
        const finalMinFreeRedeem = await esToken.minFreeRedeem()
        const finalfreeRedeemCooldown = await esToken.freeRedeemCooldown()
        const finalRedemptionGracePeriod = await esToken.redemptionGracePeriod()

        expect(finalMinRedeemRatio).to.eq(newMinRedeemRatio).to.not.eq(oldMinRedeemRatio);
        expect(finalMaxRedeemRatio).to.eq(newMaxRedeemRatio).to.not.eq(oldMaxRedeemRatio);
        expect(finalMinRedeemDuration).to.eq(newMinRedeemDuration).to.not.eq(oldMinRedeemDuration);
        expect(finalMaxRedeemDuration).to.eq(newMaxRedeemDuration).to.not.eq(oldMaxRedeemDuration);
        expect(finalFreeRedeemPercentage).to.eq(newFreeRedeemPercentage).to.not.eq(oldFreeRedeemPercentage);
        expect(finalMinFreeRedeem).to.eq(newMinFreeRedeem).to.not.eq(oldMinFreeRedeem);
        expect(finalfreeRedeemCooldown).to.eq(newfreeRedeemCooldown).to.not.eq(oldfreeRedeemCooldown);
        expect(finalRedemptionGracePeriod).to.eq(newRedemptionGracePeriod).to.not.eq(oldRedemptionGracePeriod);

        let eveEsToken = esToken.connect(other);

        await expect(eveEsToken.updateRedeemSettings(
            newMinRedeemRatio,
            newMaxRedeemRatio,
            newMinRedeemDuration,
            newMaxRedeemDuration,
            0, //redeemDividends
            newFreeRedeemPercentage,
            newMinFreeRedeem,
            newfreeRedeemCooldown,
            newRedemptionGracePeriod
        )).to.be.revertedWith("Ownable: caller is not the owner")

    });

    it("can't insta redeem, can redeem partially or full if enough wait time, can use allowance after redemption", async () => {

        await alb.approve(esToken.address, decimals.pow(2));

        await esToken.convert(decimals.mul(30000));
        await esToken.approve(esToken.address, decimals.pow(2));

        await expect(esToken.redeem(decimals.mul(10000), secondsInDay * 1)).to.be.revertedWith("redeem: invalid request")

        await expect(esToken.redeem(decimals.mul(10000), secondsInDay * 15)).to.emit(esToken, "Redeem")
            .withArgs(wallet.address, decimals.mul(10000), decimals.mul(5000), secondsInDay * 15)

        await expect(esToken.redeem(decimals.mul(10000), secondsInDay * 30)).to.emit(esToken, "Redeem")
            .withArgs(wallet.address, decimals.mul(10000), decimals.mul(10000), secondsInDay * 30)

        let maxAmount = decimals.mul(30000).mul(await esToken.freeRedeemPercentage()).div(10000).add(await esToken.minFreeRedeem());
        await expect(esToken.redeem(decimals.mul(300), 0)).to.emit(esToken, "FinalizeRedeem")
            .withArgs(wallet.address, maxAmount, maxAmount)


    })

    it("can't redeem above maxAmount, can't redeem twice", async () => {

        await alb.approve(esToken.address, decimals.pow(2));

        await esToken.convert(decimals.mul(30000));

        await esToken.approve(esToken.address, decimals.pow(2));

        await expect(esToken.redeem(decimals.mul(10000), 0)).to.be.revertedWith("redeem: invalid request")

        //  emit FinalizeRedeem(userAddress, esTokenAmount, tokenAmount);
        
        //can't redeem above max
        //minFreeRedeem is 0 by default
        let maxAmount = decimals.mul(30000).mul(await esToken.freeRedeemPercentage()).div(10000).add(await esToken.minFreeRedeem());

        console.log("maxAmount", maxAmount.toString());
        await expect(esToken.redeem(maxAmount.add(1), 0)).to.be.revertedWith("redeem: invalid request")

        const preBalance = await alb.balanceOf(wallet.address)

        //can't redeem twice in a row
        await expect(esToken.redeem(maxAmount, 0)).to.emit(esToken, "FinalizeRedeem")
            .withArgs(wallet.address, maxAmount, maxAmount)

        const postBalance = await alb.balanceOf(wallet.address);

        expect(postBalance.sub(preBalance)).to.eq(maxAmount)


        let newMax = (await esToken.balanceOf(wallet.address)).mul(await esToken.freeRedeemPercentage()).div(10000).add(await esToken.minFreeRedeem());
        await expect(esToken.redeem(newMax, 0)).to.be.revertedWith("redeem: invalid request")

    })

    it("can redeem twice after waiting for cooldown, can redeem normally", async () => {

        await alb.approve(esToken.address, decimals.pow(2));
        await esToken.convert(decimals.mul(30000));
        await esToken.approve(esToken.address, decimals.pow(2));

        let maxAmount = decimals.mul(30000).mul(await esToken.freeRedeemPercentage()).div(10000).add(await esToken.minFreeRedeem());
        //can't redeem twice in a row
        await expect(esToken.redeem(maxAmount, 0)).to.emit(esToken, "FinalizeRedeem")
            .withArgs(wallet.address, maxAmount, maxAmount)

        let newMax = (await esToken.balanceOf(wallet.address)).mul(await esToken.freeRedeemPercentage()).div(10000).add(await esToken.minFreeRedeem());
        
        let time = (await provider.getBlock()).timestamp
        await provider.send("evm_mine", [time + (12*60*60 + 100)]);
        
        await expect(esToken.redeem(newMax, 0)).to.emit(esToken, "FinalizeRedeem")
            .withArgs(wallet.address, newMax, newMax)

        await esToken.redeem(decimals.mul(10000), secondsInDay * 15)

        let treasuryAddress = await esToken.treasuryAddress();
        console.log("treasury", treasuryAddress)
        time = (await provider.getBlock()).timestamp
        await provider.send("evm_mine", [time + (secondsInDay * 15 + 100)]);
        
        await expect(esToken.finalizeRedeem(0)).to.emit(esToken, "FinalizeRedeem")
            .withArgs(wallet.address, decimals.mul(10000), decimals.mul(5000));

        await esToken.redeem(decimals.mul(10000), secondsInDay * 30)

        time = (await provider.getBlock()).timestamp
        await provider.send("evm_mine", [time + (secondsInDay * 30 + 100)]);
            
        await expect(esToken.finalizeRedeem(0)).to.emit(esToken, "FinalizeRedeem")
            .withArgs(wallet.address, decimals.mul(10000), decimals.mul(10000));

    })



    it("can't redeem after a week, can reset and redeem properly afterwards", async () => {

        await alb.approve(esToken.address, decimals.pow(2));
        await esToken.convert(decimals.mul(30000));
        await esToken.approve(esToken.address, decimals.pow(2));

        await esToken.redeem(decimals.mul(10000), secondsInDay * 30)

        time = (await provider.getBlock()).timestamp
        await provider.send("evm_mine", [time + (secondsInDay * 38 + 100)]);
            
        await expect(esToken.finalizeRedeem(0)).to.be.revertedWith('finalizeRedeem: grace period expired')

        await esToken.cancelRedeem(0);

        await esToken.redeem(decimals.mul(10000), secondsInDay * 30)

        time = (await provider.getBlock()).timestamp
        await provider.send("evm_mine", [time + (secondsInDay * 30 + 100)]);

        await expect(esToken.finalizeRedeem(0)).to.emit(esToken, "FinalizeRedeem")
            .withArgs(wallet.address, decimals.mul(10000), decimals.mul(10000));

    })


    it('can add esToken to farm, can allocate, can farm', async () => {

        // function add(
    //     uint256 _allocPoint,
    //     IEsToken _esToken,
    //     uint256 _harvestInterval,
    //     IComplexRewarder[] calldata _rewarders
    // ) public onlyOwner {

        await esMaster.add(
            100,
            esToken.address,
            30,
            []
        )

        await alb.approve(esToken.address, decimals.pow(2));
        await esToken.convert(decimals.mul(30000));
        
        await esToken.approveUsage(esMaster.address, decimals.mul(30000));
        // function approveUsage(IEsTokenUsage usage, uint256 amount) external nonReentrant {
        // function allocate(address usageAddress, uint256 amount, bytes calldata usageData) external nonReentrant {
        await esToken.allocate(esMaster.address, decimals.mul(30000), '0x')

        let data = await esMaster.poolInfo(1)

        expect(data.totalLp).to.eq(decimals.mul(30000))

        let userData = await esMaster.userInfo(1, wallet.address);

        console.log("data", userData)

        expect(userData.amount).to.eq(decimals.mul(30000));


        let time = (await provider.getBlock()).timestamp
        await provider.send("evm_mine", [time + (12*60*60 + 100)]);
        
        let newTime = (await provider.getBlock()).timestamp
        let preBalance = await alb.balanceOf(wallet.address);
        await esMaster.harvest(1);

        let postBalance = await alb.balanceOf(wallet.address)

        expect(postBalance.sub(preBalance)).to.eq(decimals.mul(15).mul(70).div(100).mul(newTime - time + 1))
        preBalance = await alb.balanceOf(wallet.address);

        time = (await provider.getBlock()).timestamp
        await provider.send("evm_mine", [time + (12*60*60 + 100)]);
        newTime = (await provider.getBlock()).timestamp

        await esToken.deallocate(esMaster.address, decimals.mul(30000), '0x')

        postBalance = await alb.balanceOf(wallet.address)

        expect(postBalance.sub(preBalance)).to.eq(decimals.mul(15).mul(70).div(100).mul(newTime - time + 1))
    })

    it('farm works despite multiple pools and farms', async () => {

        // function add(
    //     uint256 _allocPoint,
    //     IEsToken _esToken,
    //     uint256 _harvestInterval,
    //     IComplexRewarder[] calldata _rewarders
    // ) public onlyOwner {

        await esMaster.add(
            100,
            esToken.address,
            30,
            []
        )

        await alb.approve(esToken.address, decimals.pow(2));
        await esToken.convert(decimals.mul(30000));
        
        await esToken.approveUsage(esMaster.address, decimals.mul(30000));
        // function approveUsage(IEsTokenUsage usage, uint256 amount) external nonReentrant {
        // function allocate(address usageAddress, uint256 amount, bytes calldata usageData) external nonReentrant {
        await esToken.allocate(esMaster.address, decimals.mul(30000), '0x')

        let data = await esMaster.poolInfo(1)

        expect(data.totalLp).to.eq(decimals.mul(30000))

        let userData = await esMaster.userInfo(1, wallet.address);

        console.log("data", userData)

        expect(userData.amount).to.eq(decimals.mul(30000));


        let time = (await provider.getBlock()).timestamp
        await provider.send("evm_mine", [time + (12*60*60 + 100)]);
        
        let newTime = (await provider.getBlock()).timestamp
        let preBalance = await alb.balanceOf(wallet.address);
        await esMaster.harvest(1);

        let postBalance = await alb.balanceOf(wallet.address)

        expect(postBalance.sub(preBalance)).to.eq(decimals.mul(15).mul(70).div(100).mul(newTime - time + 1))
        preBalance = await alb.balanceOf(wallet.address);

        //add different alloc here to main chef

        let oldTokenPerSec = await esMaster.tokenPerSec()
        // console.log("Block number before adding", (await provider.getBlock()).number)
        await masterController.add(10, alb.address, 0, 30, [])
        // console.log("Block number after adding", (await provider.getBlock()).number)
        await esMaster.updateEmissionRate();
        time = (await provider.getBlock()).timestamp
        // console.log("Block number after updating", (await provider.getBlock()).number)

        let newTokenPerSec = await esMaster.tokenPerSec()
        console.log("newTokenPerSec", ethers.utils.formatEther(newTokenPerSec))
        expect(newTokenPerSec).to.lt(oldTokenPerSec)

        await provider.send("evm_mine", [time + (12*60*60 + 100)]);
        newTime = (await provider.getBlock()).timestamp

        await esToken.deallocate(esMaster.address, decimals.mul(30000), '0x')

        postBalance = await alb.balanceOf(wallet.address)
        const expectedBalance = decimals.mul(15).mul(35).div(100).mul(newTime - time + 1)
        //we expect half the usual rate, within a small tolerance due to block shifting
        expect((postBalance.sub(preBalance)).sub(expectedBalance)).to.lt(decimals.mul(25))

    })

    it('farm doesnt brick if there is no update for some time', async () => {

        // function add(
    //     uint256 _allocPoint,
    //     IEsToken _esToken,
    //     uint256 _harvestInterval,
    //     IComplexRewarder[] calldata _rewarders
    // ) public onlyOwner {

        await esMaster.add(
            100,
            esToken.address,
            30,
            []
        )

        await alb.approve(esToken.address, decimals.pow(2));
        await esToken.convert(decimals.mul(30000));
        
        await esToken.approveUsage(esMaster.address, decimals.mul(30000));
        // function approveUsage(IEsTokenUsage usage, uint256 amount) external nonReentrant {
        // function allocate(address usageAddress, uint256 amount, bytes calldata usageData) external nonReentrant {
        await esToken.allocate(esMaster.address, decimals.mul(30000), '0x')

        let data = await esMaster.poolInfo(1)

        expect(data.totalLp).to.eq(decimals.mul(30000))

        let userData = await esMaster.userInfo(1, wallet.address);

        console.log("data", userData)

        expect(userData.amount).to.eq(decimals.mul(30000));


        let time = (await provider.getBlock()).timestamp
        await provider.send("evm_mine", [time + (12*60*60 + 100)]);
        
        let newTime = (await provider.getBlock()).timestamp
        let preBalance = await alb.balanceOf(wallet.address);
        await esMaster.harvest(1);

        let postBalance = await alb.balanceOf(wallet.address)

        expect(postBalance.sub(preBalance)).to.eq(decimals.mul(15).mul(70).div(100).mul(newTime - time + 1))
        preBalance = await alb.balanceOf(wallet.address);

        //add different alloc here to main chef

        let oldTokenPerSec = await esMaster.tokenPerSec()
        // console.log("Block number before adding", (await provider.getBlock()).number)
        await masterController.add(10, alb.address, 0, 30, [])
        // console.log("Block number after adding", (await provider.getBlock()).number)
        // await esMaster.updateEmissionRate();
        time = (await provider.getBlock()).timestamp
        // console.log("Block number after updating", (await provider.getBlock()).number)

        await provider.send("evm_mine", [time + (12*60*60 + 100)]);
        newTime = (await provider.getBlock()).timestamp

        await esToken.deallocate(esMaster.address, decimals.mul(30000), '0x')
        let newTokenPerSec = await esMaster.tokenPerSec()
        console.log("newTokenPerSec", ethers.utils.formatEther(newTokenPerSec))
        expect(newTokenPerSec).to.lt(oldTokenPerSec)

        postBalance = await alb.balanceOf(wallet.address)
        const expectedBalance = decimals.mul(15).mul(35).div(100).mul(newTime - time + 1)
        //we expect half the usual rate, within a small tolerance due to block shifting
        expect((postBalance.sub(preBalance)).sub(expectedBalance)).to.lt(decimals.mul(70))

        let esMasterBalance = await alb.balanceOf(esMaster.address)
        expect(esMasterBalance).to.eq('0')

    })


})