import { ethers } from "hardhat"

async function main() {
  const contractAddr = process.env.CONTRACT_ADDRESS!
  if (!contractAddr) {
    throw new Error("Missing CONTRACT_ADDRESS. Set env CONTRACT_ADDRESS=0x...")
  }

  const c = await ethers.getContractAt("VietlotCommitRevealV3", contractAddr)

  console.log("Unpausing contract...")
  console.log("Contract address:", contractAddr)

  try {
    await c.unpause.staticCall()
  } catch (e: any) {
    console.error(
      "unpause would revert:",
      e.shortMessage || e.reason || e.message,
    )
    console.error("Gợi ý: Đảm bảo ví hiện tại là owner của contract.")
    process.exit(1)
  }

  const tx = await c.unpause()
  console.log("Transaction hash:", tx.hash)

  const rcpt = await tx.wait()
  console.log("✅ Contract unpaused successfully!")
  console.log("Block number:", rcpt?.blockNumber)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
