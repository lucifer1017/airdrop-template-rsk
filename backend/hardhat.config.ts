import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import { configVariable, defineConfig } from "hardhat/config";

export default defineConfig({
  plugins: [hardhatToolboxViemPlugin],
  solidity: {
    profiles: {
      default: {
        version: "0.8.28",
      },
      production: {
        version: "0.8.28",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    },
  },
  networks: {
    hardhatMainnet: {
      type: "edr-simulated",
      chainType: "l1",
    },
    hardhatOp: {
      type: "edr-simulated",
      chainType: "op",
    },
    sepolia: {
      type: "http",
      chainType: "l1",
      url: configVariable("SEPOLIA_RPC_URL"),
      accounts: [configVariable("SEPOLIA_PRIVATE_KEY")],
    },
    
rskTestnet:{
      type:"http",
      chainId:31,
      gasPrice:6000000000,
      url:configVariable("RSK_TESTNET_RPC_URL"),
      accounts:[configVariable("RSK_TESTNET_PRIVATE_KEY")]

    },
    rskMainnet:{
      type:"http",
      chainId:30,
      gasPrice:6000000000,
      url:configVariable("RSK_MAINNET_RPC_URL"),
      accounts:[configVariable("RSK_MAINNET_PRIVATE_KEY")]
    }
  },
});
