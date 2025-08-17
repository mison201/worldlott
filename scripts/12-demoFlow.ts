// scripts/12-demoFlow.ts
import { ethers, network } from "hardhat"

const toWei = (v: string | number) => ethers.parseEther(String(v))
async function timeJump(sec: number) {
  await network.provider.send("evm_increaseTime", [sec])
  await network.provider.send("evm_mine")
}
function sortAsc(nums: number[]): number[] {
  return [...nums].sort((a, b) => a - b)
}
function normalizeSaltToBytes32(input?: string): `0x${string}` {
  const v = (input ?? process.env.SALT ?? "").trim()
  if (!v)
    return ("0x" +
      Buffer.from(ethers.randomBytes(32)).toString("hex")) as `0x${string}`
  if (ethers.isHexString(v))
    return ethers.hexlify(
      ethers.zeroPadValue(v as `0x${string}`, 32),
    ) as `0x${string}`
  return ethers.id(v) as `0x${string}`
}
function abiEncodeRoundNumbersSaltUser(
  roundId: number,
  numbers: number[],
  salt: `0x${string}`,
  user: string,
) {
  const coder = ethers.AbiCoder.defaultAbiCoder()
  return coder.encode(
    ["uint256", "uint8[]", "bytes32", "address"],
    [roundId, numbers, salt, user],
  )
}

/** ===== replicate _drawUniqueNumbers in TS (MUST match contract) ===== */
function drawFromWords(k: number, n: number, r0: bigint, r1: bigint): number[] {
  const bag: number[] = Array.from({ length: n }, (_, i) => i + 1)
  const out: number[] = new Array(k)
  for (let i = 0; i < k; i++) {
    const seedHex = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["uint256", "uint256", "uint8"],
        [r0, r1, i],
      ),
    )
    const seed = BigInt(seedHex)
    const idx = Number(seed % BigInt(n - i))
    out[i] = bag[idx]
    bag[idx] = bag[n - 1 - i]
  }
  // sort ascending
  out.sort((a, b) => a - b)
  return out
}
function countMatches(a: number[], b: number[]) {
  let i = 0,
    j = 0,
    c = 0
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) {
      c++
      i++
      j++
    } else if (a[i] < b[j]) i++
    else j++
  }
  return c
}

async function main() {
  const [owner, userA, userB] = await ethers.getSigners()

  // ===== 1) Deploy VietlotCommitRevealLocal =====
  const K = Number(process.env.K || 6)
  const N = Number(process.env.N || 55)
  const TICKET = toWei(process.env.TICKET_PRICE ?? "1")
  const FEE = Number(process.env.FEE_BPS || 500)
  const PK = Number(process.env.PRIZE_BPS_K || 7000)
  const PK1 = Number(process.env.PRIZE_BPS_K1 || 2000)
  const PK2 = Number(process.env.PRIZE_BPS_K2 || 500)

  const SalesSecs = Number(process.env.SALES_SECONDS || 120)
  const RevealSecs = Number(process.env.REVEAL_SECONDS || 120)

  const L = await ethers.getContractFactory("VietlotCommitRevealLocal")
  const lot = await L.connect(owner).deploy(K, N, TICKET, FEE, PK, PK1, PK2)
  await lot.waitForDeployment()
  const addr = await lot.getAddress()
  console.log("VietlotCommitRevealLocal:", addr)

  // ===== 2) Open round =====
  const now = Math.floor(Date.now() / 1000)
  const salesStart = now,
    salesEnd = now + SalesSecs,
    revealEnd = salesEnd + RevealSecs
  await lot.openRound.staticCall(salesStart, salesEnd, revealEnd)
  await (await lot.openRound(salesStart, salesEnd, revealEnd)).wait()
  const rid = Number((await lot.currentRoundId()).toString())
  const price: bigint = await lot.ticketPrice()
  console.log(
    "Opened round",
    rid,
    " | ticketPrice =",
    ethers.formatEther(price),
  )

  // ===== 3) Players & numbers =====
  const aNums = sortAsc([1, 7, 12, 23, 34, 55]) // bạn đổi tuỳ ý
  const bNums = sortAsc([2, 9, 15, 27, 31, 46])
  const aSalt = normalizeSaltToBytes32("demo-user-a")
  const bSalt = normalizeSaltToBytes32("demo-user-b")

  const aCommit = ethers.keccak256(
    abiEncodeRoundNumbersSaltUser(rid, aNums, aSalt, await userA.getAddress()),
  )
  const bCommit = ethers.keccak256(
    abiEncodeRoundNumbersSaltUser(rid, bNums, bSalt, await userB.getAddress()),
  )

  // ===== 4) Commit =====
  console.log("== Commit phase ==")
  await (
    await lot.connect(userA).commitBuy(aCommit, 1n, { value: price })
  ).wait()
  await (
    await lot.connect(userB).commitBuy(bCommit, 1n, { value: price })
  ).wait()
  console.log("Committed A & B")

  // ===== 5) Jump to reveal =====
  await timeJump(SalesSecs + 1)
  console.log("→ passed salesEnd")

  console.log("== Reveal phase ==")
  await (await lot.connect(userA).reveal(rid, aNums, aSalt, 1n)).wait()
  await (await lot.connect(userB).reveal(rid, bNums, bSalt, 1n)).wait()
  console.log("Revealed A & B")

  // ===== 6) Jump to after reveal for draw =====
  await timeJump(RevealSecs + 1)
  console.log("→ passed revealEnd")

  // ===== 7) Request draw =====
  const fee: bigint = await lot.getRequestPrice()
  await lot.requestDraw.staticCall({ value: fee })
  const txDraw = await lot.requestDraw({ value: fee })
  const rc = await txDraw.wait()

  // Parse requestId
  const iface = new ethers.Interface([
    "event DrawRequested(uint256 indexed id, uint256 requestId, uint256 paidFee)",
  ])
  let reqId = 0n
  for (const log of rc!.logs) {
    try {
      const parsed = iface.parseLog(log as any)
      if (parsed?.name === "DrawRequested") {
        reqId = parsed.args.requestId as bigint
        break
      }
    } catch {}
  }
  if (reqId === 0n) throw new Error("Không bắt được requestId")

  // ===== 8) FORCE-WIN (optional) =====
  const TARGET = Number(process.env.TARGET_MATCHES || 4) // 4|5|6
  const WHO = (process.env.FORCE_WIN_FOR || "A").toUpperCase() // A|B
  const targetTicket = WHO === "B" ? bNums : aNums

  // Brute-force r0 until matches >= TARGET (use small search space, usually finds fast)
  let foundR0: bigint | null = null,
    foundR1: bigint | null = null,
    foundWin: number[] = []
  const MAX_ITERS = Number(process.env.MAX_ITERS || 20000)
  for (let i = 1; i <= MAX_ITERS; i++) {
    const r0 = BigInt(i) * 0x9e3779b97f4a7c15n // step with golden ratio constant
    const r1 = (r0 ^ 0xabcdef1234567890n) + 17n // any derivation
    const win = drawFromWords(K, N, r0, r1)
    if (countMatches(targetTicket, win) >= TARGET) {
      foundR0 = r0
      foundR1 = r1
      foundWin = win
      break
    }
  }
  if (foundR0 === null) {
    console.log(
      `⚠️  Không tìm được seeds thỏa TARGET_MATCHES=${TARGET} trong ${MAX_ITERS} lần lặp. Dùng mặc định.`,
    )
    foundR0 = 123n
    foundR1 = 456n
    foundWin = drawFromWords(K, N, foundR0, foundR1)
  } else {
    console.log(
      `✅ Tìm thấy seeds cho ${WHO} với >=${TARGET} matches:`,
      foundWin,
    )
  }

  // Fulfill bằng seeds đã tìm
  await (await lot._shimFulfill(reqId, [foundR0!, foundR1!])).wait()
  const win = await lot.getWinningNumbers(rid)
  console.log(
    "Winning numbers:",
    win.map((x: bigint) => Number(x)),
  )

  // ===== 9) Try claim =====
  async function tryClaim(who: any, label: string, nums: number[]) {
    try {
      const tx = await lot.connect(who).claim(rid, nums, 1n)
      const r = await tx.wait()
      console.log(`✅ ${label} claim OK | tx: ${r?.hash}`)
    } catch (e: any) {
      console.log(
        `ℹ️  ${label} claim skipped:`,
        e.shortMessage || e.reason || e.message,
      )
    }
  }
  await tryClaim(userA, "User A", aNums)
  await tryClaim(userB, "User B", bNums)

  // ===== 10) Summary =====
  const sales: bigint = await lot.getSalesAmount(rid)
  const [pool, drawn] = await lot.getPrizePool(rid)
  const [opFee, drawable, paid] = await lot.getOperatorFee(rid)
  const bal: bigint = await ethers.provider.getBalance(addr)

  console.log("\n== Round summary ==")
  console.log("salesAmount     :", ethers.formatEther(sales))
  console.log("prizePoolLocked :", ethers.formatEther(pool), "| drawn:", drawn)
  console.log(
    "operatorFee     :",
    ethers.formatEther(opFee),
    "| drawable:",
    drawable,
    "| paid:",
    paid,
  )
  console.log("contract balance:", ethers.formatEther(bal))
  console.log("\nDemo done.")
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
