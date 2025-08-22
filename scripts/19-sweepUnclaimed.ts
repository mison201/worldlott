import { ethers } from "hardhat"

async function main() {
  const contractAddr = process.env.CONTRACT_ADDRESS!
  const roundId = Number(process.env.ROUND_ID || 1)
  const to =
    process.env.SWEEP_TO || (await (await ethers.getSigners())[0].getAddress())

  if (!contractAddr) {
    throw new Error("Missing CONTRACT_ADDRESS. Set env CONTRACT_ADDRESS=0x...")
  }

  const c = await ethers.getContractAt("VietlotCommitRevealV3", contractAddr)

  console.log("Sweeping unclaimed prizes...")
  console.log("Contract address:", contractAddr)
  console.log("Round ID:", roundId)
  console.log("Sweep to:", to)

  try {
    await c.sweepUnclaimed.staticCall(roundId, to)
  } catch (e: any) {
    console.error(
      "sweepUnclaimed would revert:",
      e.shortMessage || e.reason || e.message,
    )
    console.error("Gợi ý:")
    console.error(" - Đảm bảo ví hiện tại là owner của contract")
    console.error(" - Round phải đã được draw và finalized")
    console.error(" - Claim deadline phải đã hết")
    console.error(" - Phải có unclaimed prizes để sweep")
    process.exit(1)
  }

  const tx = await c.sweepUnclaimed(roundId, to)
  console.log("Transaction hash:", tx.hash)

  const rcpt = await tx.wait()
  console.log("✅ Unclaimed prizes swept successfully!")
  console.log("Block number:", rcpt?.blockNumber)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
