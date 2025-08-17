import { ethers } from "hardhat"

function getNewPriceWei(): bigint {
  // Ưu tiên NEW_TICKET_PRICE_WEI; nếu không có sẽ dùng NEW_TICKET_PRICE (ETH/STT) để parse
  const wei = process.env.NEW_TICKET_PRICE_WEI
  if (wei && wei.trim().length > 0) return BigInt(wei)
  const eth = process.env.NEW_TICKET_PRICE || "1" // ví dụ 1 STT
  return ethers.parseEther(eth)
}

async function main() {
  const addr = process.env.CONTRACT_ADDRESS!
  if (!addr) throw new Error("Missing CONTRACT_ADDRESS env")

  const c = await ethers.getContractAt("VietlotCommitReveal", addr)

  // Đọc tham số hiện tại
  const n: bigint = await c.n()
  const oldPrice: bigint = await c.ticketPrice()
  const feeBps: bigint = await c.feeBps()
  const pK: bigint = await c.prizeBpsK()
  const pK1: bigint = await c.prizeBpsK_1()
  const pK2: bigint = await c.prizeBpsK_2()

  const newPrice: bigint = getNewPriceWei()

  console.log("Contract        :", addr)
  console.log(
    "Old ticketPrice :",
    oldPrice.toString(),
    `(~${ethers.formatEther(oldPrice)} STT)`,
  )
  console.log(
    "New ticketPrice :",
    newPrice.toString(),
    `(~${ethers.formatEther(newPrice)} STT)`,
  )
  console.log(
    "Other params    : n =",
    n.toString(),
    "| feeBps =",
    feeBps.toString(),
    "| prizeBps =",
    pK.toString(),
    pK1.toString(),
    pK2.toString(),
  )

  // Dry-run để bắt lỗi (ONLY_OWNER, BPS_SUM, BAD_N, ...)
  try {
    await c.setParams.staticCall(
      Number(n.toString()),
      newPrice,
      Number(feeBps.toString()),
      Number(pK.toString()),
      Number(pK1.toString()),
      Number(pK2.toString()),
    )
  } catch (e: any) {
    console.error(
      "setParams would revert:",
      e.shortMessage || e.reason || e.message,
    )
    console.error("Gợi ý: Đảm bảo ví hiện tại là owner của contract.")
    process.exit(1)
  }

  // Gửi giao dịch
  const tx = await c.setParams(
    Number(n.toString()),
    newPrice,
    Number(feeBps.toString()),
    Number(pK.toString()),
    Number(pK1.toString()),
    Number(pK2.toString()),
  )
  console.log("Tx sent:", tx.hash)
  const rcpt = await tx.wait()
  console.log("✅ Updated. Block =", rcpt?.blockNumber)

  const check: bigint = await c.ticketPrice()
  console.log(
    "ticketPrice now :",
    check.toString(),
    `(~${ethers.formatEther(check)} STT)`,
  )
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
