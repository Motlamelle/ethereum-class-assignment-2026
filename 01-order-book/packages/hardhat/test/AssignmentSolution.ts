import { expect } from "chai";
import { ethers } from "hardhat";
import { FNBToken, OrderBook, PNPToken } from "../typechain-types";

describe("Assignment Solution", function () {
  const INITIAL_SUPPLY = ethers.parseUnits("1000000", 18);
  const TRADE_AMOUNT = ethers.parseUnits("10", 18);
  const SMALL_TRADE_AMOUNT = ethers.parseUnits("4", 18);
  const PRICE = 2n;

  let tokenA: PNPToken;
  let tokenB: FNBToken;
  let orderBook: OrderBook;

  beforeEach(async () => {
    const [deployer] = await ethers.getSigners();

    const tokenAFactory = await ethers.getContractFactory("PNPToken");
    tokenA = (await tokenAFactory.deploy(INITIAL_SUPPLY)) as PNPToken;
    await tokenA.waitForDeployment();

    const tokenBFactory = await ethers.getContractFactory("FNBToken");
    tokenB = (await tokenBFactory.deploy(INITIAL_SUPPLY)) as FNBToken;
    await tokenB.waitForDeployment();

    const orderBookFactory = await ethers.getContractFactory("OrderBook");
    orderBook = (await orderBookFactory.deploy(await tokenA.getAddress(), await tokenB.getAddress())) as OrderBook;
    await orderBook.waitForDeployment();

    expect(await tokenA.balanceOf(deployer.address)).to.equal(INITIAL_SUPPLY);
    expect(await tokenB.balanceOf(deployer.address)).to.equal(INITIAL_SUPPLY);
  });

  describe("Part 1 - ERC20 tokens", function () {
    it("1", async () => {
      expect(await tokenA.name()).to.equal("PNP Token");
      expect(await tokenA.symbol()).to.equal("PNPT");
      expect(await tokenA.totalSupply()).to.equal(INITIAL_SUPPLY);

      expect(await tokenB.name()).to.equal("FNB Token");
      expect(await tokenB.symbol()).to.equal("FNBT");
      expect(await tokenB.totalSupply()).to.equal(INITIAL_SUPPLY);
    });

    it("supports transfers", async () => {
      const [, alice] = await ethers.getSigners();
      const amount = ethers.parseUnits("100", 18);

      await tokenA.transfer(alice.address, amount);
      expect(await tokenA.balanceOf(alice.address)).to.equal(amount);
    });

    it("supports approve and transferFrom", async () => {
      const [, alice, bob] = await ethers.getSigners();
      const amount = ethers.parseUnits("50", 18);

      await tokenA.transfer(alice.address, amount);
      await tokenA.connect(alice).approve(bob.address, amount);
      await tokenA.connect(bob).transferFrom(alice.address, bob.address, amount);

      expect(await tokenA.balanceOf(alice.address)).to.equal(0);
      expect(await tokenA.balanceOf(bob.address)).to.equal(amount);
    });
  });

  describe("Part 2 - Order book", function () {
    async function seedAndApprove() {
      const [, buyer, seller] = await ethers.getSigners();
      const buyerQuote = TRADE_AMOUNT * PRICE;

      await tokenB.transfer(buyer.address, buyerQuote);
      await tokenA.transfer(seller.address, TRADE_AMOUNT);

      await tokenB.connect(buyer).approve(await orderBook.getAddress(), buyerQuote);
      await tokenA.connect(seller).approve(await orderBook.getAddress(), TRADE_AMOUNT);

      return { buyer, seller, buyerQuote };
    }

    it("places buy and sell orders", async () => {
      const { buyer, seller } = await seedAndApprove();

      await expect(orderBook.connect(buyer).placeBuyOrder(TRADE_AMOUNT, PRICE))
        .to.emit(orderBook, "OrderPlaced")
        .withArgs(0, buyer.address, 0, await tokenB.getAddress(), await tokenA.getAddress(), TRADE_AMOUNT, PRICE);

      await expect(orderBook.connect(seller).placeSellOrder(TRADE_AMOUNT, PRICE))
        .to.emit(orderBook, "OrderPlaced")
        .withArgs(1, seller.address, 1, await tokenA.getAddress(), await tokenB.getAddress(), TRADE_AMOUNT, PRICE);
    });

    it("matches full orders and settles both tokens", async () => {
      const { buyer, seller, buyerQuote } = await seedAndApprove();

      await orderBook.connect(buyer).placeBuyOrder(TRADE_AMOUNT, PRICE);
      await orderBook.connect(seller).placeSellOrder(TRADE_AMOUNT, PRICE);

      await expect(orderBook.matchOrders(0, 1)).to.emit(orderBook, "OrderMatched");

      expect(await tokenA.balanceOf(buyer.address)).to.equal(TRADE_AMOUNT);
      expect(await tokenB.balanceOf(seller.address)).to.equal(buyerQuote);
      expect(await orderBook.isOpen(0)).to.equal(false);
      expect(await orderBook.isOpen(1)).to.equal(false);
    });

    it("supports partial fills and buy-order cancellation refunds", async () => {
      const [, buyer, seller] = await ethers.getSigners();
      const buyerQuote = TRADE_AMOUNT * PRICE;
      const sellerAmount = SMALL_TRADE_AMOUNT;

      await tokenB.transfer(buyer.address, buyerQuote);
      await tokenA.transfer(seller.address, sellerAmount);

      await tokenB.connect(buyer).approve(await orderBook.getAddress(), buyerQuote);
      await tokenA.connect(seller).approve(await orderBook.getAddress(), sellerAmount);

      await orderBook.connect(buyer).placeBuyOrder(TRADE_AMOUNT, PRICE);
      await orderBook.connect(seller).placeSellOrder(sellerAmount, PRICE);

      await orderBook.matchOrders(0, 1);
      expect(await orderBook.remaining(0)).to.equal(ethers.parseUnits("6", 18));

      await expect(orderBook.connect(buyer).cancelOrder(0)).to.emit(orderBook, "OrderCanceled");

      // Buyer gets 4 TokenA from trade and 12 TokenB refunded from remaining buy order.
      expect(await tokenA.balanceOf(buyer.address)).to.equal(SMALL_TRADE_AMOUNT);
      expect(await tokenB.balanceOf(buyer.address)).to.equal(ethers.parseUnits("12", 18));
      expect(await orderBook.isOpen(0)).to.equal(false);
    });

    it("reverts for invalid orders and unauthorized actions", async () => {
      const [, buyer, seller, attacker] = await ethers.getSigners();
      const buyerQuote = TRADE_AMOUNT * PRICE;

      await expect(orderBook.connect(buyer).placeBuyOrder(0, PRICE)).to.be.revertedWithCustomError(
        orderBook,
        "InvalidAmount",
      );
      await expect(orderBook.connect(seller).placeSellOrder(TRADE_AMOUNT, 0)).to.be.revertedWithCustomError(
        orderBook,
        "InvalidPrice",
      );

      await tokenB.transfer(buyer.address, buyerQuote);
      await tokenA.transfer(seller.address, TRADE_AMOUNT);
      await tokenB.connect(buyer).approve(await orderBook.getAddress(), buyerQuote);
      await tokenA.connect(seller).approve(await orderBook.getAddress(), TRADE_AMOUNT);

      await orderBook.connect(buyer).placeBuyOrder(TRADE_AMOUNT, 1);
      await orderBook.connect(seller).placeSellOrder(TRADE_AMOUNT, 2);

      await expect(orderBook.matchOrders(0, 1)).to.be.revertedWithCustomError(orderBook, "PriceMismatch");
      await expect(orderBook.connect(attacker).cancelOrder(0)).to.be.revertedWithCustomError(
        orderBook,
        "UnauthorizedCancellation",
      );
    });
  });
});
