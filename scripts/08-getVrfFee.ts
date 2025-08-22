import { ethers } from "hardhat"
async function main() {
  const addr = process.env.CONTRACT_ADDRESS!
  const c = await ethers.getContractAt("VietlotCommitRevealV3", addr)
  const fee: bigint = await c.getRequestPrice()
  console.log(
    "VRF fee (wei):",
    fee.toString(),
    "| (~STT):",
    Number(ethers.formatEther(fee)),
  )
}
main().catch((e) => {
  console.error(e)
  process.exit(1)
})
