// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// ══════════════════════════════════════════════════════════════════════════════
//
//   ARBITRAJ BOTU v7.0 — "Kuantum Mermi" Kontratı
//   Base Network — Gas-Minimized Flash Swap Arbitrage Engine
//
//   4 Devasa Mimari Değişiklik:
//
//   1. SAF CALLDATA OKUMASI (Assembly)
//      • Fonksiyon parametresi YOK — fallback() ile giriş
//      • calldataload ile ham byte okuması (73 byte kompakt format)
//      • Memory tahsisi SIFIR — stack üzerinde çalışır
//
//   2. EIP-1153 TRANSIENT STORAGE (Callback Yönetimi)
//      • TSTORE/TLOAD ile geçici hafıza — SSTORE maliyetinin ~%95 altında
//      • Callback bağlamı (expectedPool, aeroPool, token'lar) anlık yazılır
//      • TX bittiğinde otomatik silinir — gas iadesi
//
//   3. OFF-CHAIN KÂR DOĞRULAMASI
//      • Kontrat içinde matematik YOK — REVM botu %100 simüle eder
//      • Sadece "Bakiye Öncesi vs Bakiye Sonrası" kontrolü
//      • Son Bakiye > İlk Bakiye ise → kâr sahibine gönderilir
//      • Değilse → tüm işlem revert edilir
//
//   4. IMMUTABLE DEĞİŞKENLER
//      • owner bytecode'a gömülü — SLOAD (2100 gas) yerine ~3 gas
//      • paused, enforceSlippage, minProfitBps → SİLİNDİ
//      • Botu durdurmak istiyorsan Rust'ı kapatırsın, kontratı değil
//
// ══════════════════════════════════════════════════════════════════════════════
//
//   KOMPAKT CALLDATA FORMATI (73 byte — ABI kodlama YOK)
//
//   Offset   Boyut   Alan
//   ─────────────────────────────────
//   0x00     20 B    Pool A adresi (Uniswap V3 — flash swap kaynağı)
//   0x14     20 B    Pool B adresi (Aerodrome — satış hedefi)
//   0x28     32 B    Miktar (uint256, big-endian)
//   0x48      1 B    Yön (0x00 = zeroForOne=true, 0x01 = false)
//   ─────────────────────────────────
//   TOPLAM   73 B    (Eski ABI: 132+ byte → %45 tasarruf)
//
// ══════════════════════════════════════════════════════════════════════════════
//
//   EIP-1153 TRANSIENT STORAGE SLOT HARİTASI
//
//   Slot     İçerik
//   ─────────────────────────
//   0x00     expectedPool   — callback çağrıcı doğrulaması
//   0x01     aeroPool       — ikinci ayak (satış) havuzu
//   0x02     token0         — Uniswap V3 havuz token0
//   0x03     token1         — Uniswap V3 havuz token1
//   0xFF     reentrancy     — kilit (1 = kilitli, 0 = açık)
//
// ══════════════════════════════════════════════════════════════════════════════

// ── CUSTOM ERRORS ────────────────────────────────────────────────────────────

/// @dev Çağrıcı yetkili değil (owner değil)
error Unauthorized();

/// @dev Callback çağrıcısı beklenen Uniswap V3 havuzu değil
error InvalidCaller();

/// @dev Arbitraj sonrası kâr elde edilemedi (bakiye artmadı)
error NoProfitRealized();

/// @dev Reentrancy tespit edildi (transient storage kilidi)
error Locked();

/// @dev İşlem miktarı sıfır
error ZeroAmount();

/// @dev ERC20 transfer başarısız
error TransferFailed();

// ── MINIMAL INTERFACES ───────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IUniswapV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);

    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IAerodromePool {
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    function getAmountOut(
        uint256 amountIn,
        address tokenIn
    ) external view returns (uint256);

    function token0() external view returns (address);
}

// ══════════════════════════════════════════════════════════════════════════════
//                            ANA KONTRAT
// ══════════════════════════════════════════════════════════════════════════════

contract ArbitrajBotu {

    // ─────────────────────────────────────────────────────────────────────────
    //  IMMUTABLE — bytecode'a gömülü, SLOAD = 0 gas
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Kontrat sahibi. Constructor'da atanır, değiştirilemez.
    ///         Bytecode'da saklanır → okuma maliyeti ~3 gas (SLOAD: 2100 gas).
    address public immutable owner;

    // ─────────────────────────────────────────────────────────────────────────
    //  CONSTANTS — Uniswap V3 sqrt price limits
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev zeroForOne=true → minimum fiyat sınırı (TickMath.MIN_SQRT_RATIO + 1)
    uint160 private constant MIN_SQRT_RATIO_PLUS_1 = 4295128740;

    /// @dev zeroForOne=false → maksimum fiyat sınırı (TickMath.MAX_SQRT_RATIO - 1)
    uint160 private constant MAX_SQRT_RATIO_MINUS_1 =
        1461446703485210103287273052203988822378723970341;

    // ─────────────────────────────────────────────────────────────────────────
    //  EVENTS
    // ─────────────────────────────────────────────────────────────────────────

    event ArbitrageExecuted(
        address indexed poolA,
        address indexed poolB,
        uint256 amountIn,
        uint256 profit
    );
    event EmergencyTokenWithdraw(
        address indexed token, uint256 amount, address indexed to
    );
    event EmergencyETHWithdraw(uint256 amount, address indexed to);

    // ─────────────────────────────────────────────────────────────────────────
    //  CONSTRUCTOR — owner immutable olarak bytecode'a yazılır
    // ─────────────────────────────────────────────────────────────────────────

    constructor() {
        owner = msg.sender;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CORE GİRİŞ NOKTASI — 73-BYTE KOMPAKT CALLDATA (fallback)
    // ═════════════════════════════════════════════════════════════════════════
    //
    //  Rust botu 73 byte sıkıştırılmış veriyi gönderir:
    //    [PoolA:20B] + [PoolB:20B] + [Miktar:32B] + [Yön:1B]
    //
    //  • Fonksiyon seçici YOK — fallback() devralır
    //  • ABI kodlama YOK — calldataload ile ham byte okuması
    //  • Memory tahsisi SIFIR — tüm değişkenler stack'te
    //
    //  Akış:
    //    1. Owner kontrolü (immutable — bytecode, ~3 gas)
    //    2. Reentrancy kilidi (TSTORE — geçici hafıza)
    //    3. Calldata çözümleme (assembly — calldataload)
    //    4. Havuz token'larını oku (2 static call)
    //    5. TSTORE callback bağlamı (EIP-1153)
    //    6. Bakiye oku (ÖNCE)
    //    7. Flash swap tetikle → callback → Aerodrome → geri öde
    //    8. Bakiye oku (SONRA) — Off-chain doğrulama
    //    9. Kâr varsa sahibine gönder, yoksa revert
    //
    // ═════════════════════════════════════════════════════════════════════════

    fallback() external {
        // ── 1. SAHİPLİK KONTROLÜ ─────────────────────────────────────────
        // Immutable → bytecode'dan okunur → SLOAD yerine PUSH, ~3 gas
        if (msg.sender != owner) revert Unauthorized();

        // ── 2. REENTRANCY KİLİDİ (EIP-1153 Transient Storage) ────────────
        // TLOAD/TSTORE: ~100 gas (SLOAD/SSTORE: 2100/5000+ gas)
        // TX bittiğinde otomatik sıfırlanır → gas iadesi alınır
        uint256 locked;
        assembly { locked := tload(0xFF) }
        if (locked != 0) revert Locked();
        assembly { tstore(0xFF, 1) }

        // ── 3. CALLDATA ÇÖZÜMLEME (Assembly — saf byte okuması) ──────────
        // calldataload(offset): offset'ten 32 byte okur
        // shr(96, x): sağa 96 bit kaydır → üst 20 byte = adres
        // shr(248, x): sağa 248 bit kaydır → üst 1 byte = yön
        address poolA;
        address poolB;
        uint256 amount;
        uint8 direction;

        assembly {
            poolA     := shr(96,  calldataload(0x00))  // [0..20]   Pool A adresi
            poolB     := shr(96,  calldataload(0x14))  // [20..40]  Pool B adresi
            amount    := calldataload(0x28)             // [40..72]  Miktar (uint256)
            direction := shr(248, calldataload(0x48))   // [72]      Yön (1 byte)
        }

        if (amount == 0) revert ZeroAmount();

        // ── 4. HAVUZ TOKEN'LARINI OKU ────────────────────────────────────
        // 2 static call (kaçınılmaz — ama sadece 1 kez, ~5200 gas toplam)
        address t0 = IUniswapV3Pool(poolA).token0();
        address t1 = IUniswapV3Pool(poolA).token1();

        // Swap yönü: direction=0 → zeroForOne=true (token0 borçlu, token1 alınır)
        //            direction=1 → zeroForOne=false (token1 borçlu, token0 alınır)
        bool zeroForOne = (direction == 0);

        // Borçlu token = kâr token (flash swap'tan sonra artması gereken)
        address owedToken = zeroForOne ? t0 : t1;

        // ── 5. TSTORE — Callback bağlamını geçici hafızaya yaz ───────────
        // Bu değerler callback içinde TLOAD ile okunacak.
        // TX bittiğinde otomatik silinir → gas iadesi.
        assembly {
            tstore(0x00, poolA)   // Slot 0: expectedPool (callback güvenliği)
            tstore(0x01, poolB)   // Slot 1: aeroPool (ikinci ayak)
            tstore(0x02, t0)      // Slot 2: token0
            tstore(0x03, t1)      // Slot 3: token1
        }

        // ── 6. BAKİYE KONTROLÜ — ÖNCE ───────────────────────────────────
        // Off-chain doğrulama: REVM botu zaten %100 simüle etti.
        // Kontrat sadece nihai güvenlik kilidi: bakiye arttı mı?
        uint256 balBefore = IERC20(owedToken).balanceOf(address(this));

        // ── 7. FLASH SWAP TETİKLE ────────────────────────────────────────
        // Uniswap V3 flash swap: token'lar ÖNCE gönderilir,
        // sonra uniswapV3SwapCallback tetiklenir, biz borcu öderiz.
        // data parametresi BOŞ — callback TLOAD kullanır (gas tasarrufu).
        uint160 priceLimit = zeroForOne
            ? MIN_SQRT_RATIO_PLUS_1
            : MAX_SQRT_RATIO_MINUS_1;

        IUniswapV3Pool(poolA).swap(
            address(this),       // recipient: biz
            zeroForOne,          // swap yönü
            // forge-lint: disable-next-line(unsafe-typecast)
            int256(amount),      // exact input
            priceLimit,          // fiyat sınırı
            ""                   // data: BOŞ (TLOAD kullanılır)
        );

        // ── 8. BAKİYE KONTROLÜ — SONRA (Off-Chain Doğrulama) ────────────
        // Tüm callback'ler tamamlandı. Flash swap atomik.
        // Tek soru: bakiye arttı mı?
        uint256 balAfter = IERC20(owedToken).balanceOf(address(this));
        if (balAfter <= balBefore) revert NoProfitRealized();

        uint256 profit = balAfter - balBefore;

        // ── 9. KÂRI SAHİBE GÖNDER ───────────────────────────────────────
        _safeTransfer(owedToken, owner, profit);

        // ── 10. TRANSIENT STORAGE TEMİZLİĞİ + EVENT ──────────────────
        // EIP-1153: Transient storage TX sonunda otomatik sıfırlanır AMA
        // aynı TX içinde birden fazla çağrı senaryosunda (composability)
        // eski değerler kalabilir. Tüm slot'ları explicit temizliyoruz.
        assembly {
            tstore(0x00, 0)  // expectedPool
            tstore(0x01, 0)  // aeroPool
            tstore(0x02, 0)  // token0
            tstore(0x03, 0)  // token1
            tstore(0xFF, 0)  // reentrancy kilidi
        }

        emit ArbitrageExecuted(poolA, poolB, amount, profit);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CALLBACK — Uniswap V3 Flash Swap Geri Çağrısı
    // ═════════════════════════════════════════════════════════════════════════
    //
    //  Uniswap V3 havuzu swap() sırasında bu fonksiyonu tetikler.
    //  Akış:
    //    1. TLOAD ile beklenen havuz doğrulaması (güvenlik)
    //    2. TLOAD ile aeroPool ve token adresleri oku
    //    3. Alınan token'ları Aerodrome'da sat (doğrudan havuz çağrısı)
    //    4. Borcu Uniswap V3'e geri öde
    //    5. Kâr kontratta kalır → fallback() kontrol eder ve sahibine gönderir
    //
    // ═════════════════════════════════════════════════════════════════════════

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata /* data — kullanılmıyor, TLOAD kullanılıyor */
    ) external {
        // ── GÜVENLİK: Sadece beklenen havuz çağırabilir (TLOAD) ──────────
        // Normal storage okuması: SLOAD = 2100 gas
        // Transient okuması:      TLOAD = 100 gas → %95 tasarruf
        address expectedPool;
        address aeroPool;
        address token0;
        address token1;

        assembly {
            expectedPool := tload(0x00)
            aeroPool     := tload(0x01)
            token0       := tload(0x02)
            token1       := tload(0x03)
        }

        if (msg.sender != expectedPool) revert InvalidCaller();

        // ── BORÇLU ve ALINAN MİKTARLARI BELİRLE ─────────────────────────
        // amount0Delta > 0 → biz havuza token0 borçluyuz (ödememiz lazım)
        // amount1Delta < 0 → havuz bize token1 gönderdi (aldığımız)
        address tokenOwed;
        address tokenReceived;
        uint256 amountOwed;
        uint256 amountReceived;

        if (amount0Delta > 0) {
            // token0 borçlu, token1 alındı
            tokenOwed      = token0;
            tokenReceived  = token1;
            // forge-lint: disable-next-line(unsafe-typecast)
            amountOwed     = uint256(amount0Delta);
            // forge-lint: disable-next-line(unsafe-typecast)
            amountReceived = uint256(-amount1Delta);
        } else {
            // token1 borçlu, token0 alındı
            tokenOwed      = token1;
            tokenReceived  = token0;
            // forge-lint: disable-next-line(unsafe-typecast)
            amountOwed     = uint256(amount1Delta);
            // forge-lint: disable-next-line(unsafe-typecast)
            amountReceived = uint256(-amount0Delta);
        }

        // ── AERODROME'DA SAT (Direct Pool Call — Router YOK) ─────────────
        // Alınan token'ları Aerodrome havuzuna gönder, karşılığında
        // borçlu token al. Router kullanmıyoruz = daha az gas.
        _aerodromeSwap(aeroPool, tokenReceived, amountReceived, tokenOwed);

        // ── UNİSWAP V3 BORCUNU ÖDE ──────────────────────────────────────
        _safeTransfer(tokenOwed, msg.sender, amountOwed);

        // Kâr kontratta kalır → fallback() bakiye farkını hesaplar
        // ve sahibine gönderir. Burada ek kontrol yapılmaz.
        // "Off-chain doğrulama" felsefesi: REVM zaten hesapladı.
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Aerodrome Doğrudan Swap (Router YOK)
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Token'ları doğrudan Aerodrome havuzuna transfer et ve swap yap.
    ///      Approve yok, router yok — transfer + swap = minimum gas.
    function _aerodromeSwap(
        address pool,
        address tokenIn,
        uint256 amountIn,
        address tokenOut
    ) internal {
        // Token'ları doğrudan havuza aktar (approve gerekmez)
        _safeTransfer(tokenIn, pool, amountIn);

        // Beklenen çıktıyı sor (view call)
        uint256 amountOut = IAerodromePool(pool).getAmountOut(amountIn, tokenIn);

        // Swap: çıktı token'ın pozisyonuna göre amount0Out veya amount1Out
        address poolToken0 = IAerodromePool(pool).token0();
        if (tokenOut == poolToken0) {
            IAerodromePool(pool).swap(amountOut, 0, address(this), "");
        } else {
            IAerodromePool(pool).swap(0, amountOut, address(this), "");
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ACİL DURUM — Token ve ETH Kurtarma
    // ═════════════════════════════════════════════════════════════════════════
    //
    //  Sıkışan token'ları veya ETH'yi kurtarmak için.
    //  paused, enforceSlippage, minProfitBps → SİLİNDİ.
    //  Botu durdurmak istiyorsan Rust'ı kapatırsın.
    //

    /// @notice Kontrattaki tüm token bakiyesini sahibine çek
    function withdrawToken(address token) external {
        if (msg.sender != owner) revert Unauthorized();
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) revert ZeroAmount();
        _safeTransfer(token, owner, bal);
        emit EmergencyTokenWithdraw(token, bal, owner);
    }

    /// @notice Kontrattaki tüm ETH bakiyesini sahibine çek
    function withdrawETH() external {
        if (msg.sender != owner) revert Unauthorized();
        uint256 bal = address(this).balance;
        if (bal == 0) revert ZeroAmount();
        (bool ok, ) = owner.call{value: bal}("");
        if (!ok) revert TransferFailed();
        emit EmergencyETHWithdraw(bal, owner);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  VIEW — Bakiye Sorgulama
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Kontrat'ın belirli bir token bakiyesini döndür
    function getBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Güvenli ERC20 Transfer (Non-Standard Token Desteği)
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Low-level call ile ERC20 transfer. USDT gibi bool dönmeyen
    ///      token'ları da destekler. Başarısız olursa revert.
    function _safeTransfer(address token, address to, uint256 amt) internal {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amt)
        );
        // Başarı koşulu: call başarılı VE (veri yok VEYA true döndü)
        if (!ok || (ret.length > 0 && !abi.decode(ret, (bool)))) {
            revert TransferFailed();
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  RECEIVE — ETH kabul (WETH unwrap iadesi vb.)
    // ═════════════════════════════════════════════════════════════════════════

    receive() external payable {}
}
