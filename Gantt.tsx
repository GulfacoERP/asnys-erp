/** Lightweight Gantt chart: one row per task, bars from start to due date, diamonds for milestones,
 *  arrows from each task's predecessor, and a line for today. Scrolls sideways on small screens. */
type Task = { id: string; title: string; start_date: string | null; due_date: string | null; status: string; percent_complete: number | null;
  predecessor_id: string | null; is_milestone: boolean };

const DAY = 864e5;
const parse = (d: string) => Date.parse(d.slice(0, 10) + 'T00:00:00Z');
const fmt = (t: number) => { const d = new Date(t); return `${d.getUTCDate()} ${['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.getUTCMonth()]}`; };

export function Gantt({ tasks, onPick }: { tasks: Task[]; onPick?: (id: string) => void }) {
  const dated = tasks.filter(t => t.start_date || t.due_date);
  if (!dated.length) return <div className="empty">Give tasks a start and due date to see them on the timeline.</div>;
  const s = (t: Task) => parse(t.start_date || t.due_date!);
  const e = (t: Task) => parse(t.due_date || t.start_date!);
  const today = parse(new Date().toISOString());
  let lo = Math.min(...dated.map(s)), hi = Math.max(...dated.map(e), lo + 7 * DAY);
  lo -= 2 * DAY; hi += 3 * DAY;
  const days = Math.round((hi - lo) / DAY);
  const pxDay = Math.max(8, Math.min(28, 900 / days));
  const LABEL = 210, ROW = 30, TOP = 34;
  const W = LABEL + days * pxDay + 20, H = TOP + dated.length * ROW + 10;
  const x = (t: number) => LABEL + ((t - lo) / DAY) * pxDay;
  const yOf = (id: string) => TOP + dated.findIndex(t => t.id === id) * ROW + ROW / 2;
  const need = 48 / pxDay, step = need <= 1 ? 1 : need <= 2 ? 2 : need <= 7 ? 7 : 14;
  const ticks: number[] = [];
  for (let t = lo; t <= hi; t += DAY * step) ticks.push(t);
  const colour = (t: Task) => (t.status === 'done' ? 'var(--good)' : t.due_date && parse(t.due_date) < today ? 'var(--bad)' : 'var(--accent)');
  return <div className="scroll">
    <svg width={W} height={H} role="img" aria-label="Project timeline" style={{ display: 'block', fontFamily: 'var(--body)' }}>
      {ticks.map(t => <g key={t}>
        <line x1={x(t)} x2={x(t)} y1={TOP - 6} y2={H} stroke="var(--line)" />
        <text x={x(t) + 3} y={TOP - 12} fontSize="11" fill="var(--muted)">{fmt(t)}</text></g>)}
      {today >= lo && today <= hi && <g><line x1={x(today)} x2={x(today)} y1={TOP - 6} y2={H} stroke="var(--bad)" strokeDasharray="4 3" />
        <text x={x(today) + 3} y={H - 2} fontSize="10" fill="var(--bad)">today</text></g>}
      {dated.map((t, i) => {
        const y = TOP + i * ROW, x1 = x(s(t)), x2 = x(e(t) + DAY), c = colour(t), pct = t.status === 'done' ? 100 : (t.percent_complete ?? (t.status === 'doing' ? 50 : 0));
        return <g key={t.id} style={{ cursor: onPick ? 'pointer' : undefined }} onClick={() => onPick?.(t.id)}>
          <rect x="0" y={y} width={W} height={ROW} fill={i % 2 ? 'transparent' : 'var(--sunk)'} opacity=".5" />
          <text x="8" y={y + ROW / 2 + 4} fontSize="12" fill="var(--fg)">{t.title.length > 30 ? t.title.slice(0, 29) + '…' : t.title}</text>
          {t.is_milestone
            ? <path d={`M${x2 - pxDay / 2} ${y + 7} l8 8 l-8 8 l-8 -8 z`} fill={c} />
            : <><rect x={x1} y={y + 8} width={Math.max(x2 - x1, 4)} height={ROW - 16} rx="4" fill={c} opacity=".25" />
              <rect x={x1} y={y + 8} width={Math.max((x2 - x1) * pct / 100, 0)} height={ROW - 16} rx="4" fill={c} />
              <text x={x2 + 5} y={y + ROW / 2 + 4} fontSize="10" fill="var(--muted)">{pct}%</text></>}
        </g>;
      })}
      {dated.filter(t => t.predecessor_id && dated.some(p => p.id === t.predecessor_id)).map(t => {
        const p = dated.find(q => q.id === t.predecessor_id)!;
        const xa = x(e(p) + DAY), ya = yOf(p.id), xb = x(s(t)), yb = yOf(t.id);
        return <path key={'d' + t.id} d={`M${xa} ${ya} H${xa + 6} V${yb} H${xb - 2}`} fill="none" stroke="var(--muted)" strokeWidth="1.2" markerEnd="url(#gantt-arrow)" />;
      })}
      <defs><marker id="gantt-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M0 0L10 5L0 10z" fill="var(--muted)" /></marker></defs>
    </svg>
  </div>;
}
