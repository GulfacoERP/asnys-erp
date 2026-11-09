import { Link } from 'react-router-dom';
import { useSession } from '../lib/session';
import { MODULES, ModuleIcon } from '../lib/modules';
import { longDate, today } from '../lib/format';
import { Dashboard } from './Dashboard';
import { AnnouncementsPanel } from './People';

/** Home: one tile per module the person's role can open, then today's figures underneath. */
export function Home() {
  const { company, can, session } = useSession();
  const mods = MODULES.map(m => ({ ...m, pages: m.pages.filter(p => !p.roles || can(...p.roles)) })).filter(m => m.pages.length);
  const h = new Date().getHours();
  const hello = h < 12 ? 'Good morning' : h < 17 ? 'Good afternoon' : 'Good evening';
  const local = (session?.user.email || '').split('@')[0].split(/[._-]/)[0];
  const name = local ? local[0].toUpperCase() + local.slice(1) : '';
  return <>
    <div className="home-head">
      <p className="muted">{longDate(today())}</p>
      <h1>{hello}{name ? `, ${name}` : ''}</h1>
      <p className="muted">{company?.name} · pick a module to start</p>
    </div>
    <nav className="launcher" aria-label="Modules">
      {mods.map(m => <Link key={m.id} to={m.pages[0].to} className="app-tile" style={{ '--hue': m.hue } as any}>
        <span className="app-tile-ico"><ModuleIcon id={m.id} size={30} /></span>
        <span className="app-tile-name">{m.name}</span>
        <span className="app-tile-blurb">{m.blurb}</span>
      </Link>)}
    </nav>
    <AnnouncementsPanel />
    <Dashboard embedded />
  </>;
}
