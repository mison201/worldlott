import { ethers } from "hardhat"

async function main() {
  const contractAddr = process.env.CONTRACT_ADDRESS!
  const c = await ethers.getContractAt("VietlotCommitReveal", contractAddr)
  const fee = await c.getRequestPrice()
  const tx = await c.requestDraw({ value: fee })
  await tx.wait()
  console.log("Draw requested. Paid fee:", fee.toString())
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
