import { ConnectButton } from '@rainbow-me/rainbowkit'
import { useEffect, useState } from 'react'
import { formatUnits, parseUnits } from 'viem'
import { useAccount, useConfig, useReadContract, useReadContracts, useSwitchChain } from 'wagmi'
import { readContract, waitForTransactionReceipt, writeContract } from 'wagmi/actions'
import { sepolia } from 'wagmi/chains'

import { DEPOSIT, NXM, VAULT, WNXM, depositAbi, erc20Abi, vaultAbi } from './contracts.ts'

type Mode = 'wNXM' | 'aNXM'

function formatAmount(value: bigint | undefined) {
  if (value === undefined) return '—'
  const [whole, frac = ''] = formatUnits(value, 18).split('.')
  const trimmed = frac.slice(0, 4).replace(/0+$/, '')
  return trimmed.length > 0 ? `${whole}.${trimmed}` : whole
}

function errorText(error: unknown) {
  if (error && typeof error === 'object' && 'shortMessage' in error) {
    return String(error.shortMessage)
  }
  if (error instanceof Error) return error.message
  return 'Transaction failed'
}

export default function App() {
  const config = useConfig()
  const { address, isConnected, chainId } = useAccount()
  const { switchChain } = useSwitchChain()
  const [mode, setMode] = useState<Mode>('aNXM')
  const [amount, setAmount] = useState('')
  const [pending, setPending] = useState(false)
  const [status, setStatus] = useState('')
  const [error, setError] = useState('')

  const onSepolia = chainId === sepolia.id

  useEffect(() => {
    if (!isConnected || chainId === undefined || chainId === sepolia.id) return
    switchChain({ chainId: sepolia.id })
  }, [isConnected, chainId, switchChain])

  const { data: owner } = useReadContract({
    address: NXM,
    abi: erc20Abi,
    functionName: 'owner',
  })

  const balances = useReadContracts({
    contracts: address
      ? [
          { address: NXM, abi: erc20Abi, functionName: 'balanceOf', args: [address] },
          { address: WNXM, abi: erc20Abi, functionName: 'balanceOf', args: [address] },
          { address: VAULT, abi: vaultAbi, functionName: 'balanceOf', args: [address] },
        ]
      : [],
    query: { enabled: Boolean(address), refetchInterval: 15_000 },
  })

  const nxmBalance = balances.data?.[0]?.result
  const wnxmBalance = balances.data?.[1]?.result
  const anxmBalance = balances.data?.[2]?.result

  const shareValue = useReadContract({
    address: VAULT,
    abi: vaultAbi,
    functionName: 'convertToAssets',
    args: anxmBalance !== undefined ? [anxmBalance] : undefined,
    query: { enabled: anxmBalance !== undefined, refetchInterval: 15_000 },
  })

  const isOwner = address !== undefined && owner !== undefined && address.toLowerCase() === owner.toLowerCase()

  function parsedAmount() {
    const value = parseUnits(amount.trim() === '' ? '0' : amount.trim(), 18)
    if (value <= 0n) throw new Error('Enter an amount greater than 0')
    return value
  }

  function fill(value: bigint | undefined) {
    if (value === undefined) return
    setAmount(formatUnits(value, 18))
  }

  async function run(action: () => Promise<void>) {
    setError('')
    setPending(true)
    try {
      await action()
      setStatus('')
      await balances.refetch()
      await shareValue.refetch()
    } catch (caught) {
      setStatus('')
      setError(errorText(caught))
    } finally {
      setPending(false)
    }
  }

  async function deposit() {
    if (!address) return
    await run(async () => {
      const value = parsedAmount()
      const allowance = await readContract(config, {
        address: NXM,
        abi: erc20Abi,
        functionName: 'allowance',
        args: [address, DEPOSIT],
      })
      if (allowance < value) {
        setStatus('Approve NXM in your wallet')
        const hash = await writeContract(config, {
          address: NXM,
          abi: erc20Abi,
          functionName: 'approve',
          args: [DEPOSIT, value],
        })
        setStatus('Waiting for the approval')
        await waitForTransactionReceipt(config, { hash })
      }
      setStatus(mode === 'aNXM' ? 'Depositing into aNXM' : 'Depositing into wNXM')
      const hash = await writeContract(config, {
        address: DEPOSIT,
        abi: depositAbi,
        functionName: 'deposit',
        args: [value, address, mode === 'aNXM'],
      })
      await waitForTransactionReceipt(config, { hash })
    })
  }

  async function withdraw() {
    if (!address) return
    await run(async () => {
      const value = parsedAmount()
      if (mode === 'wNXM') {
        setStatus('Redeeming wNXM for NXM')
        const hash = await writeContract(config, {
          address: DEPOSIT,
          abi: depositAbi,
          functionName: 'redeem',
          args: [value, address],
        })
        await waitForTransactionReceipt(config, { hash })
        return
      }

      const assets = await readContract(config, {
        address: VAULT,
        abi: vaultAbi,
        functionName: 'previewRedeem',
        args: [value],
      })
      if (assets === 0n) throw new Error('That share amount redeems to 0 wNXM')

      setStatus('Redeeming aNXM for wNXM')
      const shareHash = await writeContract(config, {
        address: VAULT,
        abi: vaultAbi,
        functionName: 'redeem',
        args: [value, address, address],
      })
      await waitForTransactionReceipt(config, { hash: shareHash })

      setStatus('Redeeming wNXM for NXM')
      const hash = await writeContract(config, {
        address: DEPOSIT,
        abi: depositAbi,
        functionName: 'redeem',
        args: [assets, address],
      })
      await waitForTransactionReceipt(config, { hash })
    })
  }

  async function mintTest() {
    if (!address) return
    await run(async () => {
      setStatus('Minting 1,000 NXM')
      const hash = await writeContract(config, {
        address: NXM,
        abi: erc20Abi,
        functionName: 'mint',
        args: [address, parseUnits('1000', 18)],
      })
      await waitForTransactionReceipt(config, { hash })
    })
  }

  const ready = isConnected && onSepolia && !pending
  const hint =
    mode === 'aNXM'
      ? 'Deposit mints vault shares. Withdraw turns aNXM back into NXM in two confirmations.'
      : 'Deposit mints wNXM 1:1. Withdraw burns wNXM and sends NXM. wNXM does not earn yield.'

  return (
    <main className="page">
      <header className="top">
        <div>
          <p className="eyebrow">Sepolia</p>
          <h1>Nexum</h1>
        </div>
        <ConnectButton chainStatus="full" showBalance={false} />
      </header>

      <p className="lede">
        Deposit NXM. Keep a 1:1 claim as wNXM, or stake it as aNXM so staking yield accrues to your shares.
      </p>

      {isConnected && !onSepolia && (
        <button className="banner" type="button" onClick={() => switchChain({ chainId: sepolia.id })}>
          Switch wallet to Ethereum Sepolia
        </button>
      )}

      <section className="balances" aria-label="Balances">
        <Balance label="NXM" value={formatAmount(nxmBalance)} />
        <Balance label="wNXM" value={formatAmount(wnxmBalance)} />
        <Balance
          label="aNXM"
          value={formatAmount(anxmBalance)}
          detail={anxmBalance !== undefined && anxmBalance > 0n ? `worth ${formatAmount(shareValue.data)} wNXM` : 'vault shares'}
        />
      </section>

      <section className="panel">
        <div className="amount-row">
          <label htmlFor="amount">Amount</label>
          <span className="maxes">
            <button className="text-button" type="button" onClick={() => fill(nxmBalance)} disabled={!isConnected || pending}>
              Max NXM
            </button>
            <button
              className="text-button"
              type="button"
              onClick={() => fill(mode === 'wNXM' ? wnxmBalance : anxmBalance)}
              disabled={!isConnected || pending}
            >
              Max {mode}
            </button>
          </span>
        </div>
        <input
          id="amount"
          inputMode="decimal"
          placeholder="0.0"
          value={amount}
          onChange={(event) => setAmount(event.target.value)}
        />

        <div className="modes" role="group" aria-label="Token">
          <button type="button" className={mode === 'wNXM' ? 'mode on' : 'mode'} onClick={() => setMode('wNXM')}>
            wNXM
          </button>
          <button type="button" className={mode === 'aNXM' ? 'mode on' : 'mode'} onClick={() => setMode('aNXM')}>
            aNXM
          </button>
        </div>
        <p className="hint">{hint}</p>

        <div className="actions">
          <button type="button" className="primary" disabled={!ready} onClick={() => void deposit()}>
            Deposit
          </button>
          <button type="button" disabled={!ready} onClick={() => void withdraw()}>
            Withdraw
          </button>
        </div>

        {isOwner && (
          <button className="text-button mint" type="button" disabled={!ready} onClick={() => void mintTest()}>
            Mint 1,000 test NXM
          </button>
        )}

        {status && <p className="status">{status}</p>}
        {error && <p className="error">{error}</p>}
      </section>
    </main>
  )
}

function Balance({ label, value, detail }: { label: string; value: string; detail?: string }) {
  return (
    <div className="balance">
      <span>{label}</span>
      <strong>{value}</strong>
      {detail && <small>{detail}</small>}
    </div>
  )
}
