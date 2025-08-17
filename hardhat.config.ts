import { HardhatUserConfig } from "hardhat/config"
import "@nomicfoundation/hardhat-toolbox"
import * as dotenv from "dotenv"
dotenv.config()

const SOMNIA_RPC = process.env.SOMNIA_RPC || "https://dream-rpc.somnia.network"
const SOMNIA_CHAIN_ID = 50312

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      viaIR: true,
    },
  },
  networks: {
    hardhat: {
      chainId: 31337,
    },
    somnia: {
      url: SOMNIA_RPC,
      chainId: SOMNIA_CHAIN_ID,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    },
  },
  // (Optional) add etherscan customChains if explorer verify API có sẵn
}

export default config
