import { getDefaultConfig } from '@rainbow-me/rainbowkit'
import { http } from 'wagmi'
import { sepolia } from 'wagmi/chains'

const projectId = import.meta.env.VITE_WALLETCONNECT_PROJECT_ID || 'nexum-sepolia-demo'

export const config = getDefaultConfig({
  appName: 'Nexum',
  projectId,
  chains: [sepolia],
  transports: {
    [sepolia.id]: http(),
  },
  ssr: false,
})
