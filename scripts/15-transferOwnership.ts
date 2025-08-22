import { ethers } from "hardhat"

async function main() {
  const contractAddr = process.env.CONTRACT_ADDRESS!
  const newOwner = process.env.NEW_OWNER!

  if (!contractAddr) {
    throw new Error("Missing CONTRACT_ADDRESS. Set env CONTRACT_ADDRESS=0x...")
  }

  if (!newOwner) {
    throw new Error("Missing NEW_OWNER. Set env NEW_OWNER=0x...")
  }

  const c = await ethers.getContractAt("VietlotCommitRevealV3", contractAddr)

  console.log("Transferring ownership...")
  console.log("Contract address:", contractAddr)
  console.log("New owner:", newOwner)

  try {
    await c.transferOwnership.staticCall(newOwner)
  } catch (e: any) {
    console.error(
      "transferOwnership would revert:",
      e.shortMessage || e.reason || e.message,
    )
    console.error(
      "Gợi ý: Đảm bảo ví hiện tại là owner của contract và NEW_OWNER không phải zero address.",
    )
    process.exit(1)
  }

  const tx = await c.transferOwnership(newOwner)
  console.log("Transaction hash:", tx.hash)

  const rcpt = await tx.wait()
  console.log("✅ Ownership transferred successfully!")
  console.log("Block number:", rcpt?.blockNumber)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
