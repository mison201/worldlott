import { ethers } from "hardhat"

async function main() {
  const addr = process.env.CONTRACT_ADDRESS!
  const c = await ethers.getContractAt("VietlotCommitReveal", addr)
  const rid = Number((await c.currentRoundId()).toString())

  const sales = await c.getSalesAmount(rid)
  const [pool, drawn] = await c.getPrizePool(rid)
  const [fee, drawable, paid] = await c.getOperatorFee(rid)
  const bal = await ethers.provider.getBalance(addr)

  console.log("roundId        :", rid)
  console.log(
    "contractBalance:",
    bal.toString(),
    `(~${ethers.formatEther(bal)} STT)`,
  )
  console.log(
    "salesAmount    :",
    sales.toString(),
    `(~${ethers.formatEther(sales)} STT)`,
  )
  console.log(
    "prizePoolLocked:",
    pool.toString(),
    `(~${ethers.formatEther(pool)} STT)`,
    "| drawn:",
    drawn,
  )
  console.log(
    "operatorFee    :",
    fee.toString(),
    `(~${ethers.formatEther(fee)} STT)`,
    "| drawable:",
    drawable,
    "| paid:",
    paid,
  )
}
main().catch((e) => {
  console.error(e)
  process.exit(1)
})
