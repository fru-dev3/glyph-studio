// The Settings page shell, extracted from App.tsx. Owns the section router /
// left-nav and composes every Settings section from its own module.
import { useEffect, useState } from "react";
import { BarChart3, Bot, Database, EyeOff, Github, Keyboard, Library, ListChecks, Lock, MessagesSquare, Network, Palette, Send, Settings as SettingsIcon, Shield, ShieldCheck, SlidersHorizontal, Smartphone, UserRound, Webhook, Wrench } from "lucide-react";
import { useInvokeQuery } from "./query";
import { useAppearance } from "./hooks";
import { SettingsHub, type HubGroup } from "./settingshub";
import { ScrollPage } from "./sectionutil";
import { RemoteSection, ShortcutsSection } from "./settings1";
import { PhoneSection } from "./remotepair";
import { DAEMON_ROWS, DaemonsSection } from "./settings2";
import { SystemActivity } from "./activitypanel";
import { MirrorPanel } from "./mirror";
import { EntitiesView } from "./entitiesview";
import { editorRow, navSection, noteToolkitGroup } from "./navdefs";
import { ToolkitSection } from "./toolkit";
import { AutonomyPanel } from "./autonomypanel";
import { GeneralSection, SafetySection } from "./settings4";
import { AboutSection, GatewayLogsCard, GatewaySection } from "./settings5";
import { IntegrationsPanel } from "./integrationspanel";
import { PrivacyConnectivitySection, type PrivacyPart } from "./settings6";
import { CouncilSettingsSection } from "./councils";
import { track } from "./telemetry";
import { ModelsSection } from "./settings7";
import { WorkspaceSection } from "./settings8";
import { ArenaHandoff } from "./arenahandoff";
import { HooksSection } from "./hookssection";
import { ProfilesSection } from "./profilessection";
import { KnowledgeSourcesSection, useKnowledgeSources } from "./knowledgesources";
import type { CliInfo } from "./types";

// Sections that are a SideSpine screen: they fill the pane edge to edge and
// scroll their column and detail on their own.
const FLUSH_SECTIONS = new Set<string>(["intent", "entities", "models", "council", "toolkit", "activity", "connections", "privacy-safety", "settings"]);

export function SettingsPanel({
  appearance,
  vaultPath,
  clis,
  onRefreshClis,
  onStartChatWith,
  bunkerEnabled,
  onBunkerChange,
  onSetupDomains,
  onVaultMoved,
  jumpTo,
}: {
  appearance: ReturnType<typeof useAppearance>;
  vaultPath: string;
  clis: CliInfo[];
  onRefreshClis: () => Promise<CliInfo[]>;
  onStartChatWith?: (cliId: string, modelId?: string) => void;
  bunkerEnabled: boolean;
  onBunkerChange: (on: boolean) => void;
  onSetupDomains?: () => void;
  onVaultMoved?: (path: string) => void;
  jumpTo?: { section: string; n: number } | null;
}) {
  // A page id (an EDITOR_NAV row) plus, for the pages that gather several
  // sections, which side row is open. Old ids resolve through navSection /
  // editorRow, so every deep link lands on the right page and row.
  const [section, setSection] = useState<string>(jumpTo?.section ? navSection(jumpTo.section) : "settings");
  const [row, setRow] = useState<string | null>(jumpTo?.section ? editorRow(jumpTo.section) : null);
  const go = (raw: string) => { setSection(navSection(raw)); setRow(editorRow(raw)); };
  // Anonymous usage signal: WHICH surface opened (a name from the telemetry
  // enum), never what's in it. One event per section change.
  useEffect(() => { track("feature_used", { feature: section.replace(/-/g, "_") }); }, [section]);
  // Allow callers (e.g. the Demo ribbon's "Switch to Production" link) to jump
  // straight to a section. The nonce makes repeat jumps to the same section fire.
  useEffect(() => {
    if (jumpTo?.section) go(jumpTo.section);
  }, [jumpTo?.n]); // eslint-disable-line react-hooks/exhaustive-deps
  // In-settings deep links dispatch this event rather than threading props.
  // Format: "section" or "section:detail"; the detail is ignored.
  useEffect(() => {
    const onJump = (e: Event) => {
      const raw = (e as CustomEvent<string>).detail;
      if (!raw) return;
      const id = raw.split(":")[0];
      noteToolkitGroup(id);
      go(id);
    };
    window.addEventListener("prevail:settings-section", onJump as EventListener);
    return () => window.removeEventListener("prevail:settings-section", onJump as EventListener);
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  // One-word statuses for the Connections rows, from what those pages read.
  // Through the shared cache: a revisit shows the last statuses at once.
  const connOn = section === "connections" ? {} : null;
  const webQ = useInvokeQuery<{ running?: boolean }>("webui_status", connOn);
  const mcpQ = useInvokeQuery<{ clients?: { registered: boolean }[] }>("mcp_install_status", connOn);
  const roleQ = useInvokeQuery<string>("machine_role_get", connOn);
  const knowQ = useKnowledgeSources(section === "connections" ? vaultPath : "");
  const mcpN = (mcpQ.data?.clients ?? []).filter((x) => x.registered).length;
  const conn: { phone?: string; mcp?: string; network?: string } = {
    phone: webQ.loading ? undefined : webQ.data?.running ? "On" : "Off",
    mcp: mcpQ.loading ? undefined : `${mcpN} client${mcpN === 1 ? "" : "s"}`,
    network: roleQ.loading ? undefined : roleQ.data === "client" ? "Client" : "Hub",
  };
  const knowN = Array.isArray(knowQ.data) ? knowQ.data.length : null;

  const connections: HubGroup[] = [{ items: [
    // What briefings and chats read (knowledge sources); the first row because it is the one people come for.
    { id: "knowledge", label: "Knowledge sources", icon: Library, tint: "knowledge", status: knowN === null ? undefined : String(knowN), render: () => <KnowledgeSourcesSection vaultPath={vaultPath} /> },
    { id: "phone", label: "Phone", icon: Smartphone, status: conn.phone, render: () => <PhoneSection /> },
    { id: "gateway", label: "Gateway", icon: MessagesSquare, render: () => <><GatewaySection /><GatewayLogsCard vaultPath={vaultPath} /></> },
    { id: "mcp", label: "MCP", icon: Wrench, status: conn.mcp, render: () => <IntegrationsPanel vaultPath={vaultPath} clis={clis} /> },
    { id: "hooks", label: "Hooks", icon: Webhook, render: () => <HooksSection vaultPath={vaultPath} /> },
    { id: "network", label: "Network", icon: Network, status: conn.network, render: () => <RemoteSection /> },
  ]}];
  const privacy = (part: PrivacyPart) => () => <PrivacyConnectivitySection enabled={bunkerEnabled} onChange={onBunkerChange} vaultPath={vaultPath} part={part} />;
  const privacySafety: HubGroup[] = [
    { heading: "Privacy", items: [
      { id: "bunker", label: "Bunker Mode", icon: ShieldCheck, status: bunkerEnabled ? "On" : "Off", render: privacy("bunker") },
      { id: "vault-lock", label: "Vault Lock", icon: Lock, render: privacy("vault-lock") },
      { id: "incognito", label: "Incognito", icon: EyeOff, render: privacy("incognito") },
      { id: "guardrail", label: "Outbound Guardrail", icon: Send, render: privacy("guardrail") },
      { id: "telemetry", label: "Telemetry", icon: BarChart3, render: privacy("telemetry") },
    ]},
    { heading: "Autonomy", items: [
      { id: "autonomy", label: "Autonomy", icon: Bot, render: () => <AutonomyPanel vaultPath={vaultPath} /> },
      // The approvals you chose not to repeat: what agents may do unasked.
      { id: "always", label: "Runs without asking", icon: ListChecks, render: privacy("always") },
    ]},
    { heading: "Safety", items: [
      { id: "safety-access", label: "Access protection", icon: Lock, render: () => <SafetySection vaultPath={vaultPath} part="access" /> },
      { id: "safety-guardrails", label: "Agent guardrails", icon: Shield, render: () => <SafetySection vaultPath={vaultPath} part="guardrails" /> },
    ]},
  ];
  const settings: HubGroup[] = [
    { heading: "General", items: [
      { id: "general", label: "Behavior", icon: SlidersHorizontal, render: () => <GeneralSection appearance={appearance} part="main" vaultPath={vaultPath} /> },
      { id: "appearance", label: "Appearance", icon: Palette, render: () => <GeneralSection appearance={appearance} part="appearance" /> },
      { id: "shortcuts", label: "Shortcuts", icon: Keyboard, render: () => <ShortcutsSection /> },
    ]},
    { heading: "Vault", items: [
      { id: "vault", label: "Vault", icon: Database, render: () => <WorkspaceSection vaultPath={vaultPath} onSetupDomains={onSetupDomains} onVaultMoved={onVaultMoved} /> },
      { id: "profiles", label: "Profiles", icon: UserRound, render: () => <ProfilesSection /> },
    ]},
    { heading: "Daemons", items: DAEMON_ROWS.map((d) => ({
      id: `daemon:${d.id}`, label: d.title, icon: d.icon, render: () => <DaemonsSection vaultPath={vaultPath} embedded sel={d.id} />,
    })) },
    { heading: "About", items: [
      { id: "about", label: "About", icon: Github, render: () => <AboutSection vaultPath={vaultPath} /> },
    ]},
  ];

  return (
    // Content-only: the Editor nav lives in the shared app sidebar (EDITOR_NAV),
    // so this panel renders just the active section. min-h-0 + flex-1 so it fills
    // the space above the footer ribbon.
    <ScrollPage key={section} testId="settings-page" flush={FLUSH_SECTIONS.has(section)}>
        {/* Full width: settings use the whole pane. */}
        
          {section === "models" && <ModelsSection clis={clis} onStartChatWith={onStartChatWith} onActivated={onRefreshClis} vaultPath={vaultPath} />}
          {section === "benchmark" && <ArenaHandoff />}
          {section === "council" && <CouncilSettingsSection clis={clis} />}
          {section === "toolkit" && <ToolkitSection vaultPath={vaultPath} />}
          {section === "intent" && <MirrorPanel vaultPath={vaultPath} title="Intent" />}
          {section === "entities" && <EntitiesView vaultPath={vaultPath} />}
          {/* Activity gathers what Prevail did (by kind) and Usage. */}
          {section === "activity" && <SystemActivity vaultPath={vaultPath} initial={row ?? undefined} />}
          {section === "connections" && <SettingsHub id="connections" title="Connections" icon={Network}
            subtitle="Knowledge sources, your phone, the gateway, MCP clients, hooks and the network." groups={connections} sel={row} onSelect={setRow} />}
          {section === "privacy-safety" && <SettingsHub id="privacy-safety" title="Privacy & Safety" icon={ShieldCheck}
            subtitle="Where your data can go and what agents may do." groups={privacySafety} sel={row} onSelect={setRow} />}
          {section === "settings" && <SettingsHub id="settings" title="Settings" icon={SettingsIcon}
            subtitle="Behavior, look, your vault and profiles, and the background workers." groups={settings} sel={row} onSelect={setRow} />}
    </ScrollPage>
  );
}
