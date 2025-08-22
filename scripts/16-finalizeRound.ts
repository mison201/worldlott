import { ethers } from "hardhat"

async function main() {
  const contractAddr = process.env.CONTRACT_ADDRESS!
  const roundId = Number(process.env.ROUND_ID || 1)

  if (!contractAddr) {
    throw new Error("Missing CONTRACT_ADDRESS. Set env CONTRACT_ADDRESS=0x...")
  }

  const c = await ethers.getContractAt("VietlotCommitRevealV3", contractAddr)

  console.log("Finalizing round...")
  console.log("Contract address:", contractAddr)
  console.log("Round ID:", roundId)

  try {
    await c.finalizeRound.staticCall(roundId)
  } catch (e: any) {
    console.error(
      "finalizeRound would revert:",
      e.shortMessage || e.reason || e.message,
    )
    console.error("Gợi ý:")
    console.error(" - Đảm bảo ví hiện tại là owner của contract")
    console.error(" - Round phải đã được draw (drawn = true)")
    console.error(" - Round chưa được finalize (finalized = false)")
    process.exit(1)
  }

  const tx = await c.finalizeRound(roundId)
  console.log("Transaction hash:", tx.hash)

  const rcpt = await tx.wait()
  console.log("✅ Round finalized successfully!")
  console.log("Block number:", rcpt?.blockNumber)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
