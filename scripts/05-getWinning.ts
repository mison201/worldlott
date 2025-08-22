import { ethers } from "hardhat"

async function main() {
  const contractAddr = process.env.CONTRACT_ADDRESS!
  const roundId = Number(process.env.ROUND_ID || 1)
  const c = await ethers.getContractAt("VietlotCommitRevealV3", contractAddr)
  const nums = await c.getWinningNumbers(roundId)
  console.log(
    "Winning numbers:",
    nums.map((x: bigint) => Number(x)),
  )
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
