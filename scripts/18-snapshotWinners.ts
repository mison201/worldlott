import { ethers } from "hardhat"

async function main() {
  const contractAddr = process.env.CONTRACT_ADDRESS!
  const roundId = Number(process.env.ROUND_ID || 1)
  const start = Number(process.env.START || 0)
  const limit = Number(process.env.LIMIT || 100)

  if (!contractAddr) {
    throw new Error("Missing CONTRACT_ADDRESS. Set env CONTRACT_ADDRESS=0x...")
  }

  const c = await ethers.getContractAt("VietlotCommitRevealV3", contractAddr)

  console.log("Snapshotting winners...")
  console.log("Contract address:", contractAddr)
  console.log("Round ID:", roundId)
  console.log("Start:", start)
  console.log("Limit:", limit)

  try {
    await c.snapshotWinners.staticCall(roundId, start, limit)
  } catch (e: any) {
    console.error(
      "snapshotWinners would revert:",
      e.shortMessage || e.reason || e.message,
    )
    console.error("Gợi ý:")
    console.error(" - Round phải đã được draw (drawn = true)")
    console.error(" - Snapshot chưa được hoàn thành (snapshotDone = false)")
    process.exit(1)
  }

  const tx = await c.snapshotWinners(roundId, start, limit)
  console.log("Transaction hash:", tx.hash)

  const rcpt = await tx.wait()
  console.log("✅ Winners snapshot processed!")
  console.log("Block number:", rcpt?.blockNumber)

  // Check if snapshot is done
  const roundInfo = await c.getRoundInfo(roundId)
  console.log("Snapshot done:", roundInfo.snapshotDone)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
