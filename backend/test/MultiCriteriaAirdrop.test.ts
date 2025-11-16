import { expect } from "chai";
import { ethers } from "hardhat";

describe("MultiCriteriaAirdrop1155", function () {
  let admin: any;
  let user1: any;
  let user2: any;
  let airdropManager: any;
  let multiCriteriaAirdrop: any;
  let myToken: any;

  // Simplified test criteria - no external dependencies
  const eligibilityCriteria = {
    stakingContract: ethers.ZeroAddress, // Disabled for testing
    minimumStakeAmount: ethers.parseUnits("100", 18),
    minimumStakeDuration: 86400 * 30, // 30 days
    minimumTransactions: 10,
    minimumContractInteractions: 5,
    rnsRegistry: ethers.ZeroAddress, // Disabled for testing
    requiredDomains: [],
    requireAnyDomain: false,
    stakingWeight: 0,  // Focus on activity scoring only
    activityWeight: 100,
    rnsWeight: 0,
    minimumScore: 60
  };

  before(async function () {
    [admin, user1, user2] = await ethers.getSigners();

    // Deploy MyToken
    myToken = await ethers.deployContract("MyToken", [admin.address], { signer: admin });
    await myToken.waitForDeployment();
    console.log("MyToken deployed at", await myToken.getAddress());

    // Deploy MultiCriteriaAirdrop
    const name = "Multi-Criteria Airdrop";
    const tokenId = 1;
    const totalAirdropAmount = ethers.parseUnits("1000", 18);
    const claimAmount = ethers.parseUnits("10", 18);
    const expirationDate = Math.floor(Date.now() / 1000) + 86400 * 7; // 7 days from now

    multiCriteriaAirdrop = await ethers.deployContract("MultiCriteriaAirdrop1155", [
      name,
      admin.address,
      await myToken.getAddress(),
      tokenId,
      totalAirdropAmount,
      claimAmount,
      expirationDate,
      eligibilityCriteria
    ], { signer: admin });
    await multiCriteriaAirdrop.waitForDeployment();
    console.log("MultiCriteriaAirdrop deployed at", await multiCriteriaAirdrop.getAddress());

    // Deploy AirdropManager
    airdropManager = await ethers.deployContract("AirdropManager", [[admin.address]], { signer: admin });
    await airdropManager.waitForDeployment();
    console.log("AirdropManager deployed at", await airdropManager.getAddress());

    // Mint tokens to the airdrop contract
    await myToken.mint(await multiCriteriaAirdrop.getAddress(), tokenId, totalAirdropAmount, "0x");
  });

  describe("Deployment and Configuration", function () {
    it("should deploy with correct configuration", async function () {
      const airdropInfo = await multiCriteriaAirdrop.getAirdropInfo();
      expect(airdropInfo.airdropName).to.equal("Multi-Criteria Airdrop");
      expect(airdropInfo.totalAirdropAmount).to.equal(ethers.parseUnits("1000", 18));
      expect(airdropInfo.claimAmount).to.equal(ethers.parseUnits("10", 18));
      expect(airdropInfo.airdropType).to.equal(2); // MULTI_CRITERIA
    });

    it("should have correct eligibility criteria", async function () {
      const criteria = await multiCriteriaAirdrop.eligibilityCriteria();
      expect(criteria.stakingWeight).to.equal(0);
      expect(criteria.activityWeight).to.equal(100);
      expect(criteria.rnsWeight).to.equal(0);
      expect(criteria.minimumScore).to.equal(60);
    });
  });

  describe("Activity Score Calculation", function () {
    it("should track and score transaction activity", async function () {
      // Track transactions for user1
      const addresses = Array(15).fill(user1.address);
      await multiCriteriaAirdrop.batchTrackTransactions(addresses);

      // Track contract interactions
      const contractAddress = await myToken.getAddress();
      await multiCriteriaAirdrop.batchTrackContractInteractions(addresses.slice(0, 8), contractAddress);

      const tx = await multiCriteriaAirdrop.calculateUserScore(user1.address);
      const receipt = await tx.wait();
      
      const scoreEvent = receipt.logs.find((log: any) => {
        try {
          const parsed = multiCriteriaAirdrop.interface.parseLog(log);
          return parsed.name === 'ScoreCalculated';
        } catch {
          return false;
        }
      });

      expect(scoreEvent).to.not.be.undefined;
      const parsedEvent = multiCriteriaAirdrop.interface.parseLog(scoreEvent);
      expect(parsedEvent.args.activityScore).to.be.gt(0);
      expect(parsedEvent.args.totalScore).to.be.gt(60); // Should meet minimum score
    });

    it("should give zero score for users with no activity", async function () {
      const tx = await multiCriteriaAirdrop.calculateUserScore(user2.address);
      const receipt = await tx.wait();
      
      const scoreEvent = receipt.logs.find((log: any) => {
        try {
          const parsed = multiCriteriaAirdrop.interface.parseLog(log);
          return parsed.name === 'ScoreCalculated';
        } catch {
          return false;
        }
      });

      const parsedEvent = multiCriteriaAirdrop.interface.parseLog(scoreEvent);
      expect(parsedEvent.args.activityScore).to.equal(0);
      expect(parsedEvent.args.totalScore).to.equal(0);
    });
  });

  describe("Integration with AirdropManager", function () {
    before(async function () {
      // Set up activity tracking before ownership transfer
      const addresses = Array(20).fill(user1.address);
      await multiCriteriaAirdrop.batchTrackTransactions(addresses);
      await multiCriteriaAirdrop.batchTrackContractInteractions(addresses.slice(0, 10), await myToken.getAddress());
      
      // Transfer ownership to AirdropManager for integration tests
      await multiCriteriaAirdrop.transferOwnership(await airdropManager.getAddress());
    });

    it("should be addable to AirdropManager", async function () {
      await airdropManager.addAirdrop(await multiCriteriaAirdrop.getAddress());
      const airdrops = await airdropManager.getAirdrops();
      expect(airdrops).to.include(await multiCriteriaAirdrop.getAddress());
    });

    it("should allow qualified users to claim through AirdropManager", async function () {
      // User1 has activity tracking from the before() block, so they should qualify
      
      // Calculate score
      await airdropManager.allowAddress(await multiCriteriaAirdrop.getAddress(), user1.address);

      // Check if user is allowed
      const isAllowed = await airdropManager.isAllowed(await multiCriteriaAirdrop.getAddress(), user1.address);
      expect(isAllowed).to.be.true;

      // Claim through AirdropManager
      await airdropManager.claim(await multiCriteriaAirdrop.getAddress(), user1.address, ethers.parseUnits("10", 18), []);

      // Check user received tokens
      const userBalance = await myToken.balanceOf(user1.address, 1);
      expect(userBalance).to.equal(ethers.parseUnits("10", 18));
    });

    it("should reject unqualified users", async function () {
      // user2 has no activity
      await airdropManager.allowAddress(await multiCriteriaAirdrop.getAddress(), user2.address);
      
      const isAllowed = await airdropManager.isAllowed(await multiCriteriaAirdrop.getAddress(), user2.address);
      expect(isAllowed).to.be.false;

      // Attempt to claim should fail
      await expect(
        airdropManager.claim(await multiCriteriaAirdrop.getAddress(), user2.address, ethers.parseUnits("10", 18), [])
      ).to.be.revertedWith("User does not meet eligibility criteria");
    });
  });

  describe("Admin Functions", function () {
    it("should allow admin to update eligibility criteria", async function () {
      // Create a new airdrop for admin testing
      const newCriteria = {
        ...eligibilityCriteria,
        stakingWeight: 0,
        activityWeight: 80,
        rnsWeight: 20,
        minimumScore: 50
      };

      const adminTestAirdrop = await ethers.deployContract("MultiCriteriaAirdrop1155", [
        "Admin Test Airdrop",
        admin.address,
        await myToken.getAddress(),
        1,
        ethers.parseUnits("100", 18),
        ethers.parseUnits("1", 18),
        Math.floor(Date.now() / 1000) + 86400 * 7,
        eligibilityCriteria
      ], { signer: admin });
      await adminTestAirdrop.waitForDeployment();

      await adminTestAirdrop.connect(admin).updateEligibilityCriteria(newCriteria);
      
      const updatedCriteria = await adminTestAirdrop.eligibilityCriteria();
      expect(updatedCriteria.activityWeight).to.equal(80);
      expect(updatedCriteria.rnsWeight).to.equal(20);
      expect(updatedCriteria.minimumScore).to.equal(50);
    });

    it("should reject criteria with invalid weights", async function () {
      const adminTestAirdrop = await ethers.deployContract("MultiCriteriaAirdrop1155", [
        "Admin Test Airdrop 2",
        admin.address,
        await myToken.getAddress(),
        1,
        ethers.parseUnits("100", 18),
        ethers.parseUnits("1", 18),
        Math.floor(Date.now() / 1000) + 86400 * 7,
        eligibilityCriteria
      ], { signer: admin });
      await adminTestAirdrop.waitForDeployment();

      const invalidCriteria = {
        ...eligibilityCriteria,
        stakingWeight: 50,
        activityWeight: 30,
        rnsWeight: 30, // Total = 110, should fail
        minimumScore: 60
      };

      await expect(
        adminTestAirdrop.connect(admin).updateEligibilityCriteria(invalidCriteria)
      ).to.be.revertedWith("Weights must sum to 100");
    });
  });
});