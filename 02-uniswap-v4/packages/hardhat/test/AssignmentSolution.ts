import { expect } from "chai";
import { ethers } from "hardhat";
import { FNBToken, PNPToken, RewardTokensManager } from "../typechain-types";
import poolManagerArtifact from "@uniswap/v4-core/out/PoolManager.sol/PoolManager.json";

describe("Uniswap v4 Assignment Solution", function () {
  const INITIAL_SUPPLY = ethers.parseUnits("1000000", 18);
  const SQRT_PRICE_X96 = 79228162514264337593543950336n; // 2^96 => price 1
  const LIQUIDITY = 1_000_000n;

  let pnpToken: PNPToken;
  let fnbToken: FNBToken;
  let poolManager: any;
  let tokensManager: RewardTokensManager;

  beforeEach(async () => {
    const pnpFactory = await ethers.getContractFactory("PNPToken");
    pnpToken = (await pnpFactory.deploy(INITIAL_SUPPLY)) as PNPToken;
    await pnpToken.waitForDeployment();

    const fnbFactory = await ethers.getContractFactory("FNBToken");
    fnbToken = (await fnbFactory.deploy(INITIAL_SUPPLY)) as FNBToken;
    await fnbToken.waitForDeployment();

    const [deployer] = await ethers.getSigners();
    const poolManagerFactory = new ethers.ContractFactory(
      poolManagerArtifact.abi,
      poolManagerArtifact.bytecode.object,
      deployer,
    );
    poolManager = await poolManagerFactory.deploy(deployer.address);
    await poolManager.waitForDeployment();

    const tokensManagerFactory = await ethers.getContractFactory("RewardTokensManager");
    tokensManager = (await tokensManagerFactory.deploy(
      await poolManager.getAddress(),
      await pnpToken.getAddress(),
      await fnbToken.getAddress(),
    )) as RewardTokensManager;
    await tokensManager.waitForDeployment();
  });

  it("creates the pool using 0.3% fee, spacing 60, no hooks, and emits PoolCreated", async () => {
    const [owner] = await ethers.getSigners();
    const tx = await tokensManager.createPool(SQRT_PRICE_X96);

    const poolId = await tokensManager.getPoolId();
    const [currency0, currency1] = await tokensManager.getCanonicalCurrencies();

    await expect(tx)
      .to.emit(tokensManager, "PoolCreated")
      .withArgs(poolId, currency0, currency1, 3000, 60, ethers.ZeroAddress, SQRT_PRICE_X96);

    expect(await tokensManager.createdPools(poolId)).to.equal(true);
    expect(await tokensManager.FEE_TIER()).to.equal(3000);
    expect(await tokensManager.TICK_SPACING()).to.equal(60);
    expect(await tokensManager.HOOKS()).to.equal(ethers.ZeroAddress);
    expect(owner.address).to.not.equal(ethers.ZeroAddress);
  });

  it("mints liquidity in same pool and emits LiquidityMinted", async () => {
    const [owner] = await ethers.getSigners();
    await tokensManager.createPool(SQRT_PRICE_X96);

    const targetTick = await tokensManager.getTargetTick();
    // Keep range aligned to spacing 60 and ensure it includes the target tick.
    const tickLower = targetTick - (targetTick % 60n) - 120n;
    const tickUpper = targetTick - (targetTick % 60n) + 120n;

    const tx = await tokensManager.mintLiquidity(Number(tickLower), Number(tickUpper), LIQUIDITY);
    const poolId = await tokensManager.getPoolId();

    await expect(tx)
      .to.emit(tokensManager, "LiquidityMinted")
      .withArgs(poolId, 0, owner.address, Number(tickLower), Number(tickUpper), LIQUIDITY);

    const position = await tokensManager.positions(0);
    expect(position.poolId).to.equal(poolId);
    expect(position.owner).to.equal(owner.address);
    expect(position.tickLower).to.equal(Number(tickLower));
    expect(position.tickUpper).to.equal(Number(tickUpper));
    expect(position.liquidity).to.equal(LIQUIDITY);
  });

  it("reverts if minted range does not cover assignment implied tick", async () => {
    await tokensManager.createPool(SQRT_PRICE_X96);
    const targetTick = await tokensManager.getTargetTick();

    // Create an aligned range that excludes the target tick.
    const alignedBase = targetTick - (targetTick % 60n);
    const tickLower = alignedBase + 120n;
    const tickUpper = alignedBase + 240n;

    await expect(
      tokensManager.mintLiquidity(Number(tickLower), Number(tickUpper), LIQUIDITY),
    ).to.be.revertedWithCustomError(tokensManager, "TickRangeDoesNotCoverAssignmentPrice");
  });
});
