import { useState, useEffect } from 'react';
import { ConnectButton } from '@rainbow-me/rainbowkit';
import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt, useBalance, useReadContracts } from 'wagmi';
import { parseEther, formatEther, type Abi } from 'viem';
import FXSwapVaultABI from './abis/FXSwapVault.json';
import PriceOracleABI from './abis/PriceOracle.json';
import bUSDABI from './abis/bUSD.json';

// ----------------------------------------------------------------
// CONFIGURATION: Update these addresses after deployment!
// ----------------------------------------------------------------
const VAULT_ADDRESS = "0x4c7F24A0f9c8615D98bC984275B5734AA300A765" as `0x${string}`; // Replace with deployed Vault Address
const ORACLE_ADDRESS = "0xBCb8a4d759a8A04e1a23259FC6a90aC3D39C21Fa" as `0x${string}`; // Replace with deployed Oracle Address
const BUSD_ADDRESS = "0xb3c60Ab43bcc56FB8ac6e87d2C20F7f521C2fbfb" as `0x${string}`;  // Replace with deployed bUSD Address

export default function App() {
  const { address, isConnected } = useAccount();
  
  // -------------------- READ STATE --------------------
  const { data: bnbBalance } = useBalance({ address });
  
  const { data: oraclePrice } = useReadContract({
    address: ORACLE_ADDRESS,
    abi: PriceOracleABI as Abi,
    functionName: 'getLatestPrice',
    query: { refetchInterval: 10000 } // Refresh every 10s
  });

  const { data: busdBalance } = useReadContract({
    address: BUSD_ADDRESS,
    abi: bUSDABI as Abi,
    functionName: 'balanceOf',
    args: [address],
    query: { enabled: !!address }
  });

  const { data: positionIdsData, refetch: refetchIds } = useReadContract({
    address: VAULT_ADDRESS,
    abi: FXSwapVaultABI as Abi,
    functionName: 'getUserPositions',
    args: [address],
    query: { enabled: !!address }
  });

  const positionIds = positionIdsData as bigint[] | undefined;

  // Fetch details for all user positions
  const { data: positionsData, refetch: refetchPositions } = useReadContracts({
    contracts: positionIds?.map((id: bigint) => ({
      address: VAULT_ADDRESS,
      abi: FXSwapVaultABI as Abi,
      functionName: 'positions',
      args: [id],
    })) || [],
    query: { enabled: !!positionIds && positionIds.length > 0 }
  });

  // -------------------- WRITE STATE --------------------
  const { writeContract, data: hash, error: writeError, isPending: isWritePending } = useWriteContract();
  const { isLoading: isConfirming, isSuccess: isConfirmed } = useWaitForTransactionReceipt({ hash });

  // Form States
  const [collateralAmount, setCollateralAmount] = useState('');
  const [mintAmount, setMintAmount] = useState('');
  const [duration, setDuration] = useState('86400'); // Default 1 day
  const [liquidateId, setLiquidateId] = useState('');

  // -------------------- HANDLERS --------------------
  const handleOpenPosition = async () => {
    if (!collateralAmount || !mintAmount) return;
    writeContract({
      address: VAULT_ADDRESS,
      abi: FXSwapVaultABI as Abi,
      functionName: 'openPosition',
      args: [parseEther(mintAmount), BigInt(duration)],
      value: parseEther(collateralAmount)
    });
  };

  const handleRepay = async (id: bigint) => {
    // Note: In a real app, you'd need to Approve bUSD first if using transferFrom,
    // but FXSwapVault.repayPosition handles logic. Ensure Vault has allowance or ownership logic.
    // For this PoC, assuming bUSD approval flow is handled or user is owner.
    // Actually, standard ERC20 requires approval.
    // Let's just call repay for the PoC, assuming approval is done or using permit (advanced).
    // *Correction*: The user must approve the Vault to spend their bUSD before repaying.
    // For this minimal UI, we'll assume the user might need to approve manually via Etherscan 
    // or we add an approve button. Let's add a quick approve button to the card.
    writeContract({
      address: VAULT_ADDRESS,
      abi: FXSwapVaultABI as Abi,
      functionName: 'repayPosition',
      args: [id]
    });
  };
  
  const handleApprove = async () => {
      writeContract({
          address: BUSD_ADDRESS,
          abi: bUSDABI as Abi,
          functionName: 'approve',
          args: [VAULT_ADDRESS, parseEther('1000000')] // Approve large amount for demo
      });
  }

  const handleLiquidate = async () => {
    if (!liquidateId) return;
    writeContract({
      address: VAULT_ADDRESS,
      abi: FXSwapVaultABI as Abi,
      functionName: 'liquidate',
      args: [BigInt(liquidateId)]
    });
  };

  // Refetch on success
  useEffect(() => {
    if (isConfirmed) {
      refetchIds();
      refetchPositions();
    }
  }, [isConfirmed, refetchIds, refetchPositions]);

  // -------------------- RENDER --------------------
  return (
    <div className="container">
      <header style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '2rem' }}>
        <h1>BNB FX-Swap</h1>
        <ConnectButton />
      </header>

      {!isConnected ? (
        <div className="card">Please connect your wallet to access the Vault.</div>
      ) : (
        <div className="grid">
          {/* STATS CARD */}
          <div className="card">
            <h2>Market & Wallet</h2>
            <p><strong>BNB Price:</strong> ${oraclePrice ? formatEther(oraclePrice as bigint) : 'Loading...'}</p>
            <p><strong>Your Balance:</strong> {bnbBalance?.formatted} {bnbBalance?.symbol}</p>
            <p><strong>bUSD Balance:</strong> {busdBalance ? formatEther(busdBalance as bigint) : '0.0'}</p>
            <button onClick={handleApprove} disabled={isWritePending} style={{marginTop: '1rem'}}>
                Approve Vault to Spend bUSD
            </button>
          </div>

          {/* OPEN POSITION CARD */}
          <div className="card">
            <h2>Open Swap Position</h2>
            <div className="input-group">
              <label>BNB Collateral</label>
              <input 
                type="number" 
                placeholder="0.1" 
                value={collateralAmount} 
                onChange={(e) => setCollateralAmount(e.target.value)} 
              />
            </div>
            <div className="input-group">
              <label>Mint bUSD (Debt)</label>
              <input 
                type="number" 
                placeholder="20.0" 
                value={mintAmount} 
                onChange={(e) => setMintAmount(e.target.value)} 
              />
            </div>
            <div className="input-group">
              <label>Duration (Seconds)</label>
              <input 
                type="number" 
                value={duration} 
                onChange={(e) => setDuration(e.target.value)} 
              />
              <small>Min: 86400 (1 day)</small>
            </div>
            <button onClick={handleOpenPosition} disabled={isWritePending || isConfirming}>
              {isWritePending ? 'Confirming...' : 'Open Position'}
            </button>
          </div>

          {/* LIQUIDATE CARD */}
           <div className="card">
            <h2>Liquidate Position</h2>
            <div className="input-group">
              <label>Position ID</label>
              <input 
                type="number" 
                placeholder="0" 
                value={liquidateId} 
                onChange={(e) => setLiquidateId(e.target.value)} 
              />
            </div>
            <button onClick={handleLiquidate} disabled={isWritePending || isConfirming}>
              Liquidate
            </button>
          </div>
        </div>
      )}

      {/* USER POSITIONS */}
      {isConnected && (
        <div style={{ marginTop: '2rem' }}>
          <h2>Your Positions</h2>
          {(!positionIds || positionIds.length === 0) ? (
            <p>No active positions found.</p>
          ) : (
            <div className="grid">
               {positionsData?.map((result: any, index: number) => {
                 const pos = result.result as [string, bigint, bigint, bigint, bigint, boolean] | undefined;
                 if (!pos) return null;
                 // Struct: owner, collateralAmount, debtAmount, startTime, maturityTimestamp, isOpen
                 const [, col, debt, , maturity, isOpen] = pos;
                 const id = positionIds?.[index];

                 if (!id || !isOpen) return null; // Skip closed positions if desired, or show them as closed

                 return (
                   <div key={id.toString()} className="card">
                     <h3>Position #{id.toString()}</h3>
                     <p><strong>Collateral:</strong> {formatEther(col)} BNB</p>
                     <p><strong>Debt:</strong> {formatEther(debt)} bUSD</p>
                     <p><strong>Maturity:</strong> {new Date(Number(maturity) * 1000).toLocaleString()}</p>
                     <button onClick={() => handleRepay(id)} disabled={isWritePending}>
                       Repay & Close
                     </button>
                   </div>
                 );
               })}
            </div>
          )}
        </div>
      )}

      {/* TRANSACTION STATUS */}
      {(isConfirming || isConfirmed || writeError) && (
        <div className="card" style={{ marginTop: '1rem', borderColor: writeError ? 'red' : '#646cff' }}>
            {isConfirming && <p>Transaction confirming...</p>}
            {isConfirmed && <p>Transaction successful!</p>}
            {writeError && <p>Error: {writeError.message.split('\n')[0]}</p>}
        </div>
      )}
    </div>
  );
}
