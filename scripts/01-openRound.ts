import { ethers } from "hardhat"
import * as dotenv from "dotenv"
dotenv.config()

async function main() {
  const contractAddr = process.env.CONTRACT_ADDRESS // nếu có -> attach
  const k = Number(process.env.K || 6)
  const n = Number(process.env.N || 55)
  const ticket = BigInt(process.env.TICKET_PRICE_WEI || "1000000000000000000")
  const feeBps = Number(process.env.FEE_BPS || 500)
  const pK = Number(process.env.PRIZE_BPS_K || 7000)
  const pK1 = Number(process.env.PRIZE_BPS_K1 || 2000)
  const pK2 = Number(process.env.PRIZE_BPS_K2 || 500)
  const vrfWrapper = process.env.VRF_WRAPPER

  // thời gian (giây)
  const salesSecs = Number(process.env.SALES_SECONDS || 3600) // mặc định 60'
  const revealSecs = Number(process.env.REVEAL_SECONDS || 3600) // mặc định 60'
  const claimSecs = Number(process.env.CLAIM_SECONDS || 0) // 0 = không dùng claim deadline

  let cAddress: string
  let c = null as any

  if (!contractAddr) {
    // Deploy mới
    if (!vrfWrapper) throw new Error("Missing VRF_WRAPPER for deploy")
    console.log("=> Deploying VietlotCommitRevealV3 ...")
    const Factory = await ethers.getContractFactory("VietlotCommitRevealV3")
    const contract = await Factory.deploy(
      vrfWrapper,
      k,
      n,
      ticket,
      feeBps,
      pK,
      pK1,
      pK2,
    )
    await contract.waitForDeployment()
    cAddress = await contract.getAddress()
    c = contract
    console.log("Deployed at:", cAddress)
    console.log("TIP: export CONTRACT_ADDRESS=", cAddress)
  } else {
    // Attach vào contract sẵn có
    cAddress = contractAddr
    console.log("=> Attaching to existing contract:", cAddress)
    c = await ethers.getContractAt("VietlotCommitRevealV3", cAddress)
  }

  // Open round mới
  const now = Math.floor(Date.now() / 1000)
  const salesStart = now
  const salesEnd = now + salesSecs
  const revealEnd = salesEnd + revealSecs
  const claimDeadline = claimSecs > 0 ? revealEnd + claimSecs : 0

  console.log(
    `Opening round: sales [${salesStart} .. ${salesEnd}) | revealEnd ${revealEnd} | claimDeadline ${
      claimDeadline || "none"
    }`,
  )
  try {
    await c.openRound.staticCall(salesStart, salesEnd, revealEnd, claimDeadline)
  } catch (e: any) {
    console.error(
      "openRound would revert:",
      e.shortMessage || e.reason || e.message,
    )
    throw e // hoặc return để dừng script
  }
  const tx = await c.openRound(salesStart, salesEnd, revealEnd, claimDeadline)
  await tx.wait()

  const rid = await c.currentRoundId()
  const price = await c.ticketPrice()
  console.log("✅ Opened round:", rid.toString())
  console.log("   ticketPrice:", price.toString())
  console.log("   contract   :", cAddress)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
