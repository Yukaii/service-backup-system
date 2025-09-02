import React, { useMemo, useState } from "react";
import { Info } from "lucide-react";
import {
  LineChart,
  Line,
  XAxis,
  YAxis,
  Tooltip,
  ResponsiveContainer,
  CartesianGrid,
  Legend,
  BarChart,
  Bar
} from "recharts";

// S3 Backup Cost Estimator
// - Calculates steady-state monthly storage cost by tier based on lifecycle durations
// - Also simulates month-by-month cost ramp-up until steady state (24 months)
// - Defaults match the user's provided pricing and lifecycle

// Utility helpers
const fmtNumber = (n: number, digits = 2) =>
  isFinite(n) ? n.toLocaleString(undefined, { maximumFractionDigits: digits, minimumFractionDigits: digits }) : "-";

const fmtUSD = (n: number) => `$${fmtNumber(n, 2)}`;

const clamp = (v: number, min: number, max: number) => Math.max(min, Math.min(max, v));

// Types
type Pricing = {
  standard: number; // S3 Standard $/GB-month
  standardIA: number; // S3 Standard-IA $/GB-month
  glacierInstant: number; // S3 Glacier Instant Retrieval $/GB-month
  glacierFlexible: number; // S3 Glacier Flexible Retrieval $/GB-month
  glacierDeep: number; // S3 Glacier Deep Archive $/GB-month
};

type Durations = {
  standard: number; // days retained in Standard before transition
  standardIA: number; // days retained in Standard-IA
  glacierInstant: number; // days in GIR
  glacierFlexible: number; // days in GFR
  glacierDeep: number; // days in Deep Archive
};

export default function S3CostEstimator() {
  // Inputs
  const [dailyAmount, setDailyAmount] = useState<number>(225.9); // default 225.9 MB/day
  const [dailyUnit, setDailyUnit] = useState<"MB" | "GB">("MB");
  const [binaryBase, setBinaryBase] = useState<boolean>(true); // true: 1024, false: 1000

  const [durations, setDurations] = useState<Durations>({
    standard: 30,
    standardIA: 30,
    glacierInstant: 120,
    glacierFlexible: 185,
    glacierDeep: 365,
  });

  const [pricing, setPricing] = useState<Pricing>({
    standard: 0.025,
    standardIA: 0.0138,
    glacierInstant: 0.005,
    glacierFlexible: 0.0045,
    glacierDeep: 0.002,
  });

  const totalRetentionDays = useMemo(
    () => durations.standard + durations.standardIA + durations.glacierInstant + durations.glacierFlexible + durations.glacierDeep,
    [durations]
  );

  const mbPerGB = binaryBase ? 1024 : 1000;

  // Convert daily input to GB/day
  const dailyGB = useMemo(() => {
    const v = isFinite(dailyAmount) ? Math.max(0, dailyAmount) : 0;
    if (dailyUnit === "GB") return v;
    return v / mbPerGB; // MB -> GB
  }, [dailyAmount, dailyUnit, mbPerGB]);

  // Validation against minimum storage duration recommendations
  const warnings: string[] = [];
  if (durations.standardIA < 30) warnings.push("Standard-IA 建議至少 30 天。");
  if (durations.glacierInstant < 90) warnings.push("Glacier Instant Retrieval 建議至少 90 天。");
  if (durations.glacierFlexible < 90) warnings.push("Glacier Flexible Retrieval 建議至少 90 天。");
  if (durations.glacierDeep < 180) warnings.push("Glacier Deep Archive 建議至少 180 天。");

  // Steady-state capacities (GB) held in each tier
  const steadyCap = {
    standard: dailyGB * durations.standard,
    standardIA: dailyGB * durations.standardIA,
    glacierInstant: dailyGB * durations.glacierInstant,
    glacierFlexible: dailyGB * durations.glacierFlexible,
    glacierDeep: dailyGB * durations.glacierDeep,
  };

  // Steady-state monthly costs
  const steadyCost = {
    standard: steadyCap.standard * pricing.standard,
    standardIA: steadyCap.standardIA * pricing.standardIA,
    glacierInstant: steadyCap.glacierInstant * pricing.glacierInstant,
    glacierFlexible: steadyCap.glacierFlexible * pricing.glacierFlexible,
    glacierDeep: steadyCap.glacierDeep * pricing.glacierDeep,
  };

  const steadyTotalGB = Object.values(steadyCap).reduce((a, b) => a + b, 0);
  const steadyTotalCost = Object.values(steadyCost).reduce((a, b) => a + b, 0);

  // Month-by-month ramp-up simulation (closed-form using partial fills)
  const monthsToSim = 24; // show first 24 months
  const cumulativeDurations = {
    d1: durations.standard,
    d2: durations.standard + durations.standardIA,
    d3: durations.standard + durations.standardIA + durations.glacierInstant,
    d4: durations.standard + durations.standardIA + durations.glacierInstant + durations.glacierFlexible,
    d5: totalRetentionDays,
  };

  const monthData = Array.from({ length: monthsToSim }, (_, i) => {
    const month = i + 1;
    const daysElapsed = month * 30; // 30-day month approximation for ramp-up

    const capStd = dailyGB * Math.min(daysElapsed, durations.standard);
    const capIA = dailyGB * Math.max(Math.min(daysElapsed - cumulativeDurations.d1, durations.standardIA), 0);
    const capGIR = dailyGB * Math.max(Math.min(daysElapsed - cumulativeDurations.d2, durations.glacierInstant), 0);
    const capGFR = dailyGB * Math.max(Math.min(daysElapsed - cumulativeDurations.d3, durations.glacierFlexible), 0);
    const capDeep = dailyGB * Math.max(Math.min(daysElapsed - cumulativeDurations.d4, durations.glacierDeep), 0);

    const costStd = capStd * pricing.standard;
    const costIA = capIA * pricing.standardIA;
    const costGIR = capGIR * pricing.glacierInstant;
    const costGFR = capGFR * pricing.glacierFlexible;
    const costDeep = capDeep * pricing.glacierDeep;

    const total = costStd + costIA + costGIR + costGFR + costDeep;

    return {
      month: `第 ${month} 月`,
      total,
      costStd,
      costIA,
      costGIR,
      costGFR,
      costDeep,
    };
  });

  return (
    <div className="min-h-screen w-full bg-gray-50 text-gray-900">
      <div className="mx-auto max-w-6xl p-6">
        <header className="mb-6 flex items-center justify-between">
          <h1 className="text-2xl font-bold">S3 備份成本估算器</h1>
          <div className="text-sm text-gray-600">穩態月費 & 月度爬升模擬（不含請求 / 取回 / 轉層 / 流量費）</div>
        </header>

        <div className="mb-6 rounded-2xl bg-white p-4 shadow text-sm text-gray-700">
          <p>
            這個工具用於估算基於 S3 生命週期策略的備份儲存成本。您可以設定每日新增資料量、各階段停留天數與各階層單價，
            工具會計算穩態的總儲存量與月費，並繪出前 24 個月的費用爬升曲線，協助您預估成本的變化。
          </p>
          <a
            href="https://github.com/Yukaii/service-backup-system"
            target="_blank"
            rel="noopener noreferrer"
            className="mt-2 inline-flex items-center gap-2 text-blue-600 hover:underline"
          >
            查看原始碼（GitHub）
          </a>
        </div>

        {/* Controls */}
        <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
          <div className="rounded-2xl bg-white p-4 shadow">
            <h2 className="mb-3 text-lg font-semibold">每日新增量</h2>
            <div className="flex items-end gap-3">
              <div className="flex-1">
                <label className="block text-sm text-gray-600">數值</label>
                <input
                  type="number"
                  step="0.0001"
                  value={dailyAmount}
                  onChange={(e) => setDailyAmount(parseFloat(e.target.value))}
                  className="mt-1 w-full rounded-xl border px-3 py-2"
                />
              </div>
              <div>
                <label className="block text-sm text-gray-600">單位</label>
                <select
                  value={dailyUnit}
                  onChange={(e) => setDailyUnit(e.target.value as any)}
                  className="mt-1 rounded-xl border px-3 py-2"
                >
                  <option>MB</option>
                  <option>GB</option>
                </select>
              </div>
            </div>
            <div className="mt-3 flex items-center gap-2">
              <input
                id="binary"
                type="checkbox"
                checked={binaryBase}
                onChange={(e) => setBinaryBase(e.target.checked)}
              />
              <label htmlFor="binary" className="text-sm text-gray-700">
                使用 1024 進位（1 GB = 1024 MB）
              </label>
            </div>
            <div className="mt-2 text-xs text-gray-500">
              目前換算：{fmtNumber(dailyGB, 6)} GB / 天
            </div>
          </div>

          <div className="rounded-2xl bg-white p-4 shadow">
            <h2 className="mb-3 text-lg font-semibold">生命週期（各階段天數）</h2>
            <div className="grid grid-cols-2 gap-3">
              <LabeledNumber label="Standard" value={durations.standard} onChange={(v) => setDurations({ ...durations, standard: clamp(v, 0, 10000) })} />
              <LabeledNumber label="Standard-IA" value={durations.standardIA} onChange={(v) => setDurations({ ...durations, standardIA: clamp(v, 0, 10000) })} />
              <LabeledNumber label="Glacier Instant" value={durations.glacierInstant} onChange={(v) => setDurations({ ...durations, glacierInstant: clamp(v, 0, 10000) })} />
              <LabeledNumber label="Glacier Flexible" value={durations.glacierFlexible} onChange={(v) => setDurations({ ...durations, glacierFlexible: clamp(v, 0, 10000) })} />
              <LabeledNumber label="Glacier Deep" value={durations.glacierDeep} onChange={(v) => setDurations({ ...durations, glacierDeep: clamp(v, 0, 10000) })} />
            </div>
            <div className="mt-2 text-xs text-gray-500">總保留天數：{totalRetentionDays} 天（到期刪除）</div>
            {warnings.length > 0 && (
              <ul className="mt-2 list-disc space-y-1 pl-5 text-xs text-amber-700">
                {warnings.map((w, i) => (
                  <li key={i}>{w}</li>
                ))}
              </ul>
            )}
          </div>

          <div className="rounded-2xl bg-white p-4 shadow">
            <h2 className="mb-3 text-lg font-semibold">價格（$/GB-月）</h2>
            <div className="grid grid-cols-2 gap-3">
              <LabeledNumber label="Standard" value={pricing.standard} step={0.0001} onChange={(v) => setPricing({ ...pricing, standard: clamp(v, 0, 1) })} />
              <LabeledNumber label="Standard-IA" value={pricing.standardIA} step={0.0001} onChange={(v) => setPricing({ ...pricing, standardIA: clamp(v, 0, 1) })} />
              <LabeledNumber label="Glacier Instant" value={pricing.glacierInstant} step={0.0001} onChange={(v) => setPricing({ ...pricing, glacierInstant: clamp(v, 0, 1) })} />
              <LabeledNumber label="Glacier Flexible" value={pricing.glacierFlexible} step={0.0001} onChange={(v) => setPricing({ ...pricing, glacierFlexible: clamp(v, 0, 1) })} />
              <LabeledNumber label="Glacier Deep" value={pricing.glacierDeep} step={0.0001} onChange={(v) => setPricing({ ...pricing, glacierDeep: clamp(v, 0, 1) })} />
            </div>
            <div className="mt-2 flex items-center gap-2 text-xs text-gray-500">
              <Info className="h-4 w-4" />
              <span>此處為每 GB-月單價；未套用容量分級（如 50TB/450TB 段）。</span>
            </div>
          </div>
        </div>

        {/* Summary cards */}
        <div className="mt-6 grid grid-cols-1 gap-4 md:grid-cols-3">
          <SummaryCard title="穩態總儲存量" value={`${fmtNumber(steadyTotalGB, 3)} GB`} subtitle="所有階層合計" />
          <SummaryCard title="穩態月費" value={fmtUSD(steadyTotalCost)} subtitle="僅儲存費" />
          <SummaryCard title="每日新增 (GB)" value={`${fmtNumber(dailyGB, 6)} GB`} subtitle={dailyUnit === "MB" ? `由 ${fmtNumber(dailyAmount)} MB/天 換算` : `${fmtNumber(dailyAmount)} GB/天`} />
        </div>

        {/* Table */}
        <div className="mt-6 overflow-hidden rounded-2xl bg-white shadow">
          <table className="min-w-full divide-y divide-gray-200">
            <thead className="bg-gray-50">
              <tr>
                <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">層級</th>
                <th className="px-4 py-3 text-right text-xs font-medium uppercase tracking-wider text-gray-500">停留天數</th>
                <th className="px-4 py-3 text-right text-xs font-medium uppercase tracking-wider text-gray-500">穩態容量 (GB)</th>
                <th className="px-4 py-3 text-right text-xs font-medium uppercase tracking-wider text-gray-500">單價 ($/GB)</th>
                <th className="px-4 py-3 text-right text-xs font-medium uppercase tracking-wider text-gray-500">穩態月費 ($)</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100">
              <TierRow name="Standard" days={durations.standard} cap={steadyCap.standard} price={pricing.standard} cost={steadyCost.standard} />
              <TierRow name="Standard-IA" days={durations.standardIA} cap={steadyCap.standardIA} price={pricing.standardIA} cost={steadyCost.standardIA} />
              <TierRow name="Glacier Instant" days={durations.glacierInstant} cap={steadyCap.glacierInstant} price={pricing.glacierInstant} cost={steadyCost.glacierInstant} />
              <TierRow name="Glacier Flexible" days={durations.glacierFlexible} cap={steadyCap.glacierFlexible} price={pricing.glacierFlexible} cost={steadyCost.glacierFlexible} />
              <TierRow name="Glacier Deep" days={durations.glacierDeep} cap={steadyCap.glacierDeep} price={pricing.glacierDeep} cost={steadyCost.glacierDeep} />
              <tr className="bg-gray-50 font-semibold">
                <td className="px-4 py-3">合計</td>
                <td className="px-4 py-3 text-right">{totalRetentionDays}</td>
                <td className="px-4 py-3 text-right">{fmtNumber(steadyTotalGB, 3)}</td>
                <td className="px-4 py-3 text-right">—</td>
                <td className="px-4 py-3 text-right">{fmtUSD(steadyTotalCost)}</td>
              </tr>
            </tbody>
          </table>
        </div>

        {/* Charts */}
        <div className="mt-6 grid grid-cols-1 gap-4 md:grid-cols-2">
          <div className="rounded-2xl bg-white p-4 shadow">
            <h3 className="mb-3 text-lg font-semibold">月費爬升（前 24 個月）</h3>
            <div className="h-64 w-full">
              <ResponsiveContainer>
                <LineChart data={monthData} margin={{ left: 8, right: 16, top: 8, bottom: 8 }}>
                  <CartesianGrid strokeDasharray="3 3" />
                  <XAxis dataKey="month" interval={3} />
                  <YAxis tickFormatter={(v) => `$${v}`}/>
                  <Tooltip formatter={(val: any) => fmtUSD(val as number)} />
                  <Legend />
                  <Line type="monotone" dataKey="total" name="總月費" strokeWidth={2} dot={false} />
                </LineChart>
              </ResponsiveContainer>
            </div>
          </div>

          <div className="rounded-2xl bg-white p-4 shadow">
            <h3 className="mb-3 text-lg font-semibold">穩態費用分佈</h3>
            <div className="h-64 w-full">
              <ResponsiveContainer>
                <BarChart data={[
                  { name: "Standard", cost: steadyCost.standard },
                  { name: "Standard-IA", cost: steadyCost.standardIA },
                  { name: "Glacier Instant", cost: steadyCost.glacierInstant },
                  { name: "Glacier Flexible", cost: steadyCost.glacierFlexible },
                  { name: "Glacier Deep", cost: steadyCost.glacierDeep },
                ]} margin={{ left: 8, right: 16, top: 8, bottom: 8 }}>
                  <CartesianGrid strokeDasharray="3 3" />
                  <XAxis dataKey="name" />
                  <YAxis tickFormatter={(v) => `$${v}`}/>
                  <Tooltip formatter={(val: any) => fmtUSD(val as number)} />
                  <Bar dataKey="cost" name="月費" />
                </BarChart>
              </ResponsiveContainer>
            </div>
          </div>
        </div>

        {/* Footnotes */}
        <div className="mt-6 rounded-2xl bg-white p-4 text-sm text-gray-600 shadow">
          <div className="font-medium">備註</div>
          <ul className="mt-2 list-disc space-y-1 pl-5">
            <li>此工具僅計 <span className="font-semibold">儲存費</span>；未計 <span className="italic">PUT/GET/清單/生命週期轉層請求費、取回費、資料對外傳輸（Data Transfer Out）</span> 與跨區/跨帳號複製費。</li>
            <li>顯示的單價直接使用您提供的 $/GB-月，不套用大容量分級價格（例如 50 TB/450 TB 區間）。</li>
            <li>月度爬升以 30 天為一個月近似；穩態計算為持續等量保留的 GB × 單價。</li>
            <li>若需要，我們可以加入容量分級、請求/轉層與取回費，以及不同區域的單價欄位。</li>
          </ul>
        </div>
      </div>
    </div>
  );
}

function LabeledNumber({ label, value, onChange, step = 1 }: { label: string; value: number; onChange: (v: number) => void; step?: number }) {
  return (
    <label className="block">
      <div className="text-sm text-gray-600">{label}</div>
      <input
        type="number"
        value={Number.isFinite(value) ? value : 0}
        step={step}
        onChange={(e) => onChange(parseFloat(e.target.value))}
        className="mt-1 w-full rounded-xl border px-3 py-2"
      />
    </label>
  );
}

function TierRow({ name, days, cap, price, cost }: { name: string; days: number; cap: number; price: number; cost: number }) {
  return (
    <tr>
      <td className="px-4 py-3">{name}</td>
      <td className="px-4 py-3 text-right">{fmtNumber(days, 0)}</td>
      <td className="px-4 py-3 text-right">{fmtNumber(cap, 3)}</td>
      <td className="px-4 py-3 text-right">{fmtUSD(price)}</td>
      <td className="px-4 py-3 text-right">{fmtUSD(cost)}</td>
    </tr>
  );
}

function SummaryCard({ title, value, subtitle }: { title: string; value: string; subtitle?: string }) {
  return (
    <div className="rounded-2xl bg-white p-4 shadow">
      <div className="text-sm text-gray-600">{title}</div>
      <div className="mt-1 text-2xl font-bold">{value}</div>
      {subtitle ? <div className="mt-1 text-xs text-gray-500">{subtitle}</div> : null}
    </div>
  );
}
