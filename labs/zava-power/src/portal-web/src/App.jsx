import { Routes, Route, NavLink } from "react-router-dom";
import Dashboard from "./pages/Dashboard";
import Outages from "./pages/Outages";
import Usage from "./pages/Usage";
import Billing from "./pages/Billing";

export default function App() {
  return (
    <div className="app">
      <header className="header">
        <div className="header-inner">
          <div className="logo">
            <span className="logo-icon">⚡</span>
            <span className="logo-text">PowerGrid</span>
            <span className="logo-sub">Zava Power Electric</span>
          </div>
          <nav className="nav">
            <NavLink to="/" end>
              Dashboard
            </NavLink>
            <NavLink to="/outages">Outage Map</NavLink>
            <NavLink to="/usage">Usage</NavLink>
            <NavLink to="/billing">Billing</NavLink>
          </nav>
        </div>
      </header>

      <main className="main">
        <Routes>
          <Route path="/" element={<Dashboard />} />
          <Route path="/outages" element={<Outages />} />
          <Route path="/usage" element={<Usage />} />
          <Route path="/billing" element={<Billing />} />
        </Routes>
      </main>

      <footer className="footer">
        <p>
          &copy; {new Date().getFullYear()} Zava Power Electric — PowerGrid
          Portal &nbsp;|&nbsp; ZeroOps Lab Demo
        </p>
      </footer>
    </div>
  );
}
