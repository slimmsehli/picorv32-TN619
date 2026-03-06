import { useState, useCallback } from "react";

// ─── SoC signal definitions ──────────────────────────────────────────────────
const PROTOCOLS = [
  {
    id: "uart0", label: "UART0", color: "#00E5FF", shortColor: "#003d45",
    signals: [
      { id: "uart0_tx", name: "TX",    dir: "O", desc: "Transmit data" },
      { id: "uart0_rx", name: "RX",    dir: "I", desc: "Receive data"  },
    ],
  },
  {
    id: "uart1", label: "UART1", color: "#00E5FF", shortColor: "#003d45",
    signals: [
      { id: "uart1_tx", name: "TX",    dir: "O", desc: "Transmit data" },
      { id: "uart1_rx", name: "RX",    dir: "I", desc: "Receive data"  },
    ],
  },
  {
    id: "spi0", label: "SPI0", color: "#FFEA00", shortColor: "#3d3700",
    signals: [
      { id: "spi0_sck",  name: "SCK",  dir: "O", desc: "Clock"         },
      { id: "spi0_mosi", name: "MOSI", dir: "O", desc: "Master out"    },
      { id: "spi0_miso", name: "MISO", dir: "I", desc: "Master in"     },
      { id: "spi0_cs0",  name: "CS0",  dir: "O", desc: "Chip select 0" },
      { id: "spi0_cs1",  name: "CS1",  dir: "O", desc: "Chip select 1" },
    ],
  },
  {
    id: "spi1", label: "SPI1", color: "#FFEA00", shortColor: "#3d3700",
    signals: [
      { id: "spi1_sck",  name: "SCK",  dir: "O", desc: "Clock"         },
      { id: "spi1_mosi", name: "MOSI", dir: "O", desc: "Master out"    },
      { id: "spi1_miso", name: "MISO", dir: "I", desc: "Master in"     },
      { id: "spi1_cs0",  name: "CS0",  dir: "O", desc: "Chip select 0" },
    ],
  },
  {
    id: "i2c0", label: "I2C0", color: "#69FF47", shortColor: "#1a3d10",
    signals: [
      { id: "i2c0_scl", name: "SCL",   dir: "IO", desc: "Clock (open-drain)" },
      { id: "i2c0_sda", name: "SDA",   dir: "IO", desc: "Data  (open-drain)" },
    ],
  },
  {
    id: "i2c1", label: "I2C1", color: "#69FF47", shortColor: "#1a3d10",
    signals: [
      { id: "i2c1_scl", name: "SCL",   dir: "IO", desc: "Clock (open-drain)" },
      { id: "i2c1_sda", name: "SDA",   dir: "IO", desc: "Data  (open-drain)" },
    ],
  },
  {
    id: "pwm", label: "PWM", color: "#FF6B35", shortColor: "#3d1a0d",
    signals: [
      { id: "pwm_ch0", name: "CH0",    dir: "O", desc: "PWM channel 0" },
      { id: "pwm_ch1", name: "CH1",    dir: "O", desc: "PWM channel 1" },
      { id: "pwm_ch2", name: "CH2",    dir: "O", desc: "PWM channel 2" },
      { id: "pwm_ch3", name: "CH3",    dir: "O", desc: "PWM channel 3" },
    ],
  },
  {
    id: "can0", label: "CAN0", color: "#FF4081", shortColor: "#3d0f1f",
    signals: [
      { id: "can0_tx", name: "TX",     dir: "O", desc: "CAN bus TX"    },
      { id: "can0_rx", name: "RX",     dir: "I", desc: "CAN bus RX"    },
    ],
  },
  {
    id: "adc", label: "ADC", color: "#B47EFF", shortColor: "#1e0d3d",
    signals: [
      { id: "adc_ch0", name: "CH0",    dir: "I", desc: "Analog input 0" },
      { id: "adc_ch1", name: "CH1",    dir: "I", desc: "Analog input 1" },
      { id: "adc_ch2", name: "CH2",    dir: "I", desc: "Analog input 2" },
      { id: "adc_ch3", name: "CH3",    dir: "I", desc: "Analog input 3" },
    ],
  },
  {
    id: "dac", label: "DAC", color: "#FF9F1C", shortColor: "#3d2600",
    signals: [
      { id: "dac_ch0", name: "CH0",    dir: "O", desc: "Analog output 0" },
      { id: "dac_ch1", name: "CH1",    dir: "O", desc: "Analog output 1" },
    ],
  },
];

const GPIO_COUNT = 16;
const GPIOS = Array.from({ length: GPIO_COUNT }, (_, i) => ({
  id: `gpio${i}`,
  label: `GPIO${i}`,
}));

// flatten all signals
const ALL_SIGNALS = PROTOCOLS.flatMap(p =>
  p.signals.map(s => ({ ...s, proto: p.id, protoLabel: p.label, color: p.color, shortColor: p.shortColor }))
);

const DIR_BADGE = {
  O:  { label: "OUT", bg: "#003d45", fg: "#00E5FF" },
  I:  { label: "IN",  bg: "#1a3d10", fg: "#69FF47" },
  IO: { label: "I/O", bg: "#2a1a00", fg: "#FF9F1C" },
};

// conflict detection: two signals on same GPIO
function getConflicts(matrix) {
  const conflicts = new Set();
  GPIOS.forEach(gpio => {
    const assigned = ALL_SIGNALS.filter(s => matrix[s.id]?.[gpio.id]);
    if (assigned.length > 1) {
      assigned.forEach(s => conflicts.add(`${s.id}|${gpio.id}`));
    }
  });
  return conflicts;
}

function getVerilogSnippet(matrix) {
  const lines = [
    "// ─── gpio_mux.v  —  Auto-generated connection matrix ───────────────────",
    `// GPIO pins: ${GPIO_COUNT}`,
    "// DO NOT EDIT — regenerate from the connection matrix tool",
    "",
    `module gpio_mux (`,
    `    input  wire        clk,`,
    `    input  wire        resetn,`,
  ];

  // ports for each protocol signal
  PROTOCOLS.forEach(p => {
    p.signals.forEach(s => {
      const full = `${p.id}_${s.name.toLowerCase()}`;
      if (s.dir === "O")       lines.push(`    input  wire        ${full},`);
      else if (s.dir === "I")  lines.push(`    output reg         ${full},`);
      else                     lines.push(`    inout  wire        ${full},`);
    });
  });

  lines.push(`    inout  wire [${GPIO_COUNT - 1}:0] gpio_pad`);
  lines.push(`);`);
  lines.push("");
  lines.push(`    reg  [${GPIO_COUNT - 1}:0] gpio_out;`);
  lines.push(`    reg  [${GPIO_COUNT - 1}:0] gpio_oe;`);
  lines.push("");

  // per-gpio mux logic
  GPIOS.forEach((gpio, idx) => {
    const assigned = ALL_SIGNALS.filter(s => matrix[s.id]?.[gpio.id]);
    if (assigned.length === 0) {
      lines.push(`    // ${gpio.label}: unassigned → Hi-Z`);
      lines.push(`    assign gpio_pad[${idx}] = 1'bz;`);
    } else {
      const s = assigned[0];
      const full = `${s.proto}_${s.name.toLowerCase()}`;
      lines.push(`    // ${gpio.label}: ${s.protoLabel}.${s.name} (${s.dir})`);
      if (s.dir === "O") {
        lines.push(`    assign gpio_pad[${idx}] = ${full};`);
      } else if (s.dir === "I") {
        lines.push(`    assign ${full} = gpio_pad[${idx}];`);
        lines.push(`    assign gpio_pad[${idx}] = 1'bz;`);
      } else {
        lines.push(`    assign gpio_pad[${idx}] = ${full};`);
        lines.push(`    assign ${full} = gpio_pad[${idx}];`);
      }
    }
    lines.push("");
  });

  lines.push("endmodule");
  return lines.join("\n");
}

// ─── Component ───────────────────────────────────────────────────────────────
export default function App() {
  const [matrix, setMatrix] = useState({});
  const [hoveredCell, setHoveredCell] = useState(null); // {sigId, gpioId}
  const [hoveredSignal, setHoveredSignal] = useState(null);
  const [hoveredGpio, setHoveredGpio] = useState(null);
  const [showVerilog, setShowVerilog] = useState(false);
  const [copied, setCopied] = useState(false);
  const [filter, setFilter] = useState("all");

  const toggle = useCallback((sigId, gpioId) => {
    setMatrix(prev => {
      const next = { ...prev, [sigId]: { ...(prev[sigId] || {}) } };
      next[sigId][gpioId] = !next[sigId][gpioId];
      if (!next[sigId][gpioId]) delete next[sigId][gpioId];
      return next;
    });
  }, []);

  const clearAll = () => setMatrix({});

  const conflicts = getConflicts(matrix);
  const totalAssigned = ALL_SIGNALS.reduce((acc, s) =>
    acc + Object.values(matrix[s.id] || {}).filter(Boolean).length, 0);

  const filteredSignals = filter === "all"
    ? ALL_SIGNALS
    : ALL_SIGNALS.filter(s => s.proto === filter);

  const verilog = getVerilogSnippet(matrix);

  const copyVerilog = () => {
    navigator.clipboard.writeText(verilog);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  // GPIO assignment summary
  const gpioSummary = GPIOS.map(gpio => {
    const assigned = ALL_SIGNALS.filter(s => matrix[s.id]?.[gpio.id]);
    return { ...gpio, assigned };
  });

  return (
    <div style={{
      fontFamily: "'JetBrains Mono', 'Fira Code', 'Courier New', monospace",
      background: "#0a0c0f",
      minHeight: "100vh",
      color: "#c8d0db",
      padding: "0",
      overflowX: "hidden",
    }}>

      {/* ── Header ── */}
      <div style={{
        background: "linear-gradient(180deg, #0d1117 0%, #111820 100%)",
        borderBottom: "1px solid #1e2d3d",
        padding: "18px 28px 14px",
        display: "flex",
        alignItems: "flex-end",
        gap: 24,
        flexWrap: "wrap",
      }}>
        <div>
          <div style={{ fontSize: 10, color: "#4a6070", letterSpacing: 3, marginBottom: 4 }}>
            PICORV32 SOC
          </div>
          <div style={{ fontSize: 22, fontWeight: 700, color: "#e8f0f8", letterSpacing: -0.5 }}>
            GPIO Connection Matrix
          </div>
          <div style={{ fontSize: 11, color: "#4a6070", marginTop: 3 }}>
            {ALL_SIGNALS.length} signals · {GPIO_COUNT} GPIO pins · {totalAssigned} connections
            {conflicts.size > 0 && (
              <span style={{ color: "#FF4444", marginLeft: 10 }}>
                ⚠ {conflicts.size / 2 | 0} conflict{(conflicts.size / 2 | 0) !== 1 ? "s" : ""}
              </span>
            )}
          </div>
        </div>

        {/* Filter */}
        <div style={{ marginLeft: "auto", display: "flex", gap: 6, flexWrap: "wrap", alignItems: "center" }}>
          <span style={{ fontSize: 10, color: "#4a6070", marginRight: 4 }}>FILTER:</span>
          {["all", ...PROTOCOLS.map(p => p.id)].map(f => {
            const proto = PROTOCOLS.find(p => p.id === f);
            return (
              <button key={f} onClick={() => setFilter(f)} style={{
                background: filter === f ? (proto?.color || "#1e2d3d") : "#111820",
                color: filter === f ? (proto ? "#000" : "#e8f0f8") : "#6a8090",
                border: `1px solid ${filter === f ? (proto?.color || "#2e3d4d") : "#1e2d3d"}`,
                borderRadius: 3,
                padding: "3px 10px",
                fontSize: 10,
                cursor: "pointer",
                fontFamily: "inherit",
                letterSpacing: 1,
                transition: "all 0.15s",
              }}>
                {f === "all" ? "ALL" : proto?.label}
              </button>
            );
          })}
          <button onClick={clearAll} style={{
            background: "#1a0a0a",
            color: "#FF4444",
            border: "1px solid #3d1010",
            borderRadius: 3,
            padding: "3px 10px",
            fontSize: 10,
            cursor: "pointer",
            fontFamily: "inherit",
            letterSpacing: 1,
            marginLeft: 8,
          }}>CLEAR ALL</button>
          <button onClick={() => setShowVerilog(v => !v)} style={{
            background: showVerilog ? "#003020" : "#111820",
            color: showVerilog ? "#00ff88" : "#69FF47",
            border: `1px solid ${showVerilog ? "#00ff88" : "#1e2d3d"}`,
            borderRadius: 3,
            padding: "3px 12px",
            fontSize: 10,
            cursor: "pointer",
            fontFamily: "inherit",
            letterSpacing: 1,
          }}>
            {showVerilog ? "HIDE VERILOG" : "VERILOG ↗"}
          </button>
        </div>
      </div>

      <div style={{ display: "flex", gap: 0 }}>

        {/* ── Matrix ── */}
        <div style={{ flex: 1, overflowX: "auto", padding: "20px 0 20px 20px" }}>
          <table style={{ borderCollapse: "collapse", tableLayout: "fixed" }}>
            <thead>
              <tr>
                {/* Signal label col */}
                <th style={{ width: 170, minWidth: 170 }} />
                <th style={{ width: 32 }} /> {/* dir */}
                {GPIOS.map(gpio => (
                  <th key={gpio.id}
                    onMouseEnter={() => setHoveredGpio(gpio.id)}
                    onMouseLeave={() => setHoveredGpio(null)}
                    style={{
                      width: 36,
                      padding: "0 0 8px",
                      textAlign: "center",
                      verticalAlign: "bottom",
                    }}
                  >
                    <div style={{
                      writingMode: "vertical-rl",
                      transform: "rotate(180deg)",
                      fontSize: 9,
                      letterSpacing: 1,
                      color: hoveredGpio === gpio.id ? "#e8f0f8" : "#4a6070",
                      transition: "color 0.1s",
                      padding: "4px 0",
                      whiteSpace: "nowrap",
                      borderLeft: hoveredGpio === gpio.id ? "1px solid #2e3d4d" : "1px solid transparent",
                    }}>
                      {gpio.label}
                    </div>
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {filteredSignals.map((sig, rowIdx) => {
                const proto = PROTOCOLS.find(p => p.id === sig.proto);
                const isFirstOfProto = filteredSignals.findIndex(s => s.proto === sig.proto) === rowIdx;
                const badge = DIR_BADGE[sig.dir];

                return (
                  <tr key={sig.id}
                    onMouseEnter={() => setHoveredSignal(sig.id)}
                    onMouseLeave={() => setHoveredSignal(null)}
                  >
                    {/* Protocol + signal name */}
                    <td style={{
                      padding: "1px 8px 1px 0",
                      whiteSpace: "nowrap",
                      borderTop: isFirstOfProto ? "1px solid #1e2d3d" : "none",
                      paddingTop: isFirstOfProto ? 8 : 1,
                    }}>
                      <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                        {isFirstOfProto ? (
                          <span style={{
                            fontSize: 10,
                            fontWeight: 700,
                            color: proto.color,
                            letterSpacing: 1,
                            background: proto.shortColor,
                            padding: "1px 6px",
                            borderRadius: 2,
                            border: `1px solid ${proto.color}33`,
                          }}>{proto.label}</span>
                        ) : (
                          <span style={{ width: 44 }} />
                        )}
                        <span style={{
                          fontSize: 11,
                          color: hoveredSignal === sig.id ? "#e8f0f8" : "#8a9ab0",
                          transition: "color 0.1s",
                        }}>{sig.name}</span>
                      </div>
                    </td>
                    {/* Dir badge */}
                    <td style={{ padding: "1px 6px 1px 0" }}>
                      <span style={{
                        fontSize: 8,
                        fontWeight: 700,
                        letterSpacing: 0.5,
                        background: badge.bg,
                        color: badge.fg,
                        padding: "1px 4px",
                        borderRadius: 2,
                        border: `1px solid ${badge.fg}44`,
                      }}>{badge.label}</span>
                    </td>
                    {/* Cells */}
                    {GPIOS.map(gpio => {
                      const key = `${sig.id}|${gpio.id}`;
                      const active = !!matrix[sig.id]?.[gpio.id];
                      const conflict = conflicts.has(key);
                      const hRow = hoveredSignal === sig.id;
                      const hCol = hoveredGpio === gpio.id;
                      const hCell = hoveredCell?.sigId === sig.id && hoveredCell?.gpioId === gpio.id;

                      return (
                        <td key={gpio.id}
                          onClick={() => toggle(sig.id, gpio.id)}
                          onMouseEnter={() => setHoveredCell({ sigId: sig.id, gpioId: gpio.id })}
                          onMouseLeave={() => setHoveredCell(null)}
                          style={{
                            width: 36,
                            height: 26,
                            textAlign: "center",
                            cursor: "pointer",
                            background: active
                              ? (conflict ? "#3d0a0a" : proto.shortColor)
                              : (hRow || hCol) ? "#111820" : "transparent",
                            transition: "background 0.08s",
                            border: "none",
                            position: "relative",
                          }}
                        >
                          <div style={{
                            width: active ? 14 : hCell ? 10 : (hRow || hCol) ? 6 : 4,
                            height: active ? 14 : hCell ? 10 : (hRow || hCol) ? 6 : 4,
                            borderRadius: active ? 3 : "50%",
                            background: active
                              ? (conflict ? "#FF3333" : proto.color)
                              : hCell ? "#2e3d4d" : (hRow || hCol) ? "#1e2d3d" : "#1a222b",
                            margin: "auto",
                            transition: "all 0.1s",
                            boxShadow: active && !conflict
                              ? `0 0 8px ${proto.color}88`
                              : active && conflict
                              ? "0 0 8px #FF333388"
                              : "none",
                          }} />
                        </td>
                      );
                    })}
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>

        {/* ── Right sidebar: GPIO summary ── */}
        <div style={{
          width: 220,
          minWidth: 220,
          background: "#0d1117",
          borderLeft: "1px solid #1e2d3d",
          padding: "20px 14px",
          overflowY: "auto",
          maxHeight: "calc(100vh - 90px)",
        }}>
          <div style={{ fontSize: 9, letterSpacing: 2, color: "#4a6070", marginBottom: 12 }}>
            PIN ASSIGNMENTS
          </div>
          {gpioSummary.map(gpio => (
            <div key={gpio.id} style={{
              marginBottom: 6,
              padding: "6px 8px",
              background: gpio.assigned.length > 1 ? "#1a0505"
                : gpio.assigned.length === 1 ? "#0d1520"
                : "transparent",
              borderRadius: 4,
              border: gpio.assigned.length > 1 ? "1px solid #3d1010"
                : gpio.assigned.length === 1 ? "1px solid #1e2d3d"
                : "1px solid transparent",
            }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                <span style={{ fontSize: 10, color: "#6a8090", letterSpacing: 1 }}>{gpio.label}</span>
                {gpio.assigned.length > 1 && (
                  <span style={{ fontSize: 8, color: "#FF4444" }}>CONFLICT</span>
                )}
              </div>
              {gpio.assigned.length === 0 ? (
                <div style={{ fontSize: 9, color: "#2e3d4d", marginTop: 2 }}>unassigned</div>
              ) : gpio.assigned.map(s => (
                <div key={s.id} style={{
                  fontSize: 10,
                  marginTop: 2,
                  display: "flex",
                  alignItems: "center",
                  gap: 4,
                }}>
                  <span style={{
                    display: "inline-block",
                    width: 6, height: 6,
                    borderRadius: 1,
                    background: s.color,
                    flexShrink: 0,
                  }} />
                  <span style={{ color: s.color }}>{s.protoLabel}</span>
                  <span style={{ color: "#6a8090" }}>.</span>
                  <span style={{ color: "#c8d0db" }}>{s.name}</span>
                </div>
              ))}
            </div>
          ))}

          {/* Conflict warning */}
          {conflicts.size > 0 && (
            <div style={{
              marginTop: 16,
              padding: "8px 10px",
              background: "#1a0505",
              border: "1px solid #FF4444",
              borderRadius: 4,
              fontSize: 9,
              color: "#FF7777",
              lineHeight: 1.6,
            }}>
              ⚠ Multiple signals on same GPIO will cause bus contention. Each GPIO pin must have at most one driver.
            </div>
          )}

          {/* Stats */}
          <div style={{
            marginTop: 16,
            padding: "8px 10px",
            background: "#0a0c10",
            borderRadius: 4,
            fontSize: 9,
            color: "#4a6070",
            lineHeight: 2,
          }}>
            <div style={{ display: "flex", justifyContent: "space-between" }}>
              <span>Assigned</span>
              <span style={{ color: "#69FF47" }}>{gpioSummary.filter(g => g.assigned.length === 1).length}</span>
            </div>
            <div style={{ display: "flex", justifyContent: "space-between" }}>
              <span>Free</span>
              <span style={{ color: "#4a6070" }}>{gpioSummary.filter(g => g.assigned.length === 0).length}</span>
            </div>
            <div style={{ display: "flex", justifyContent: "space-between" }}>
              <span>Conflicts</span>
              <span style={{ color: conflicts.size > 0 ? "#FF4444" : "#4a6070" }}>
                {gpioSummary.filter(g => g.assigned.length > 1).length}
              </span>
            </div>
          </div>
        </div>
      </div>

      {/* ── Verilog panel ── */}
      {showVerilog && (
        <div style={{
          margin: "0 20px 20px",
          background: "#0d1117",
          border: "1px solid #1e3020",
          borderRadius: 6,
          overflow: "hidden",
        }}>
          <div style={{
            background: "#0a1810",
            padding: "8px 14px",
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            borderBottom: "1px solid #1e3020",
          }}>
            <span style={{ fontSize: 10, color: "#69FF47", letterSpacing: 2 }}>
              gpio_mux.v  —  GENERATED OUTPUT
            </span>
            <button onClick={copyVerilog} style={{
              background: copied ? "#003020" : "#111820",
              color: copied ? "#00ff88" : "#69FF47",
              border: "1px solid #1e3020",
              borderRadius: 3,
              padding: "3px 12px",
              fontSize: 9,
              cursor: "pointer",
              fontFamily: "inherit",
              letterSpacing: 1,
            }}>
              {copied ? "✓ COPIED" : "COPY"}
            </button>
          </div>
          <pre style={{
            margin: 0,
            padding: "14px 18px",
            fontSize: 10,
            lineHeight: 1.7,
            color: "#8ab0a0",
            overflowX: "auto",
            maxHeight: 400,
            overflowY: "auto",
          }}>
            {verilog.split("\n").map((line, i) => {
              const isComment = line.trim().startsWith("//");
              const isKeyword = /^(module|endmodule|input|output|inout|assign|reg|wire)\b/.test(line.trim());
              return (
                <div key={i} style={{
                  color: isComment ? "#3a6050"
                    : isKeyword ? "#00E5FF"
                    : line.includes("gpio_pad") ? "#FFEA00"
                    : "#8ab0a0",
                }}>{line || " "}</div>
              );
            })}
          </pre>
        </div>
      )}

      {/* ── Legend ── */}
      <div style={{
        padding: "10px 20px 20px",
        display: "flex",
        gap: 20,
        flexWrap: "wrap",
        borderTop: "1px solid #1e2d3d",
        marginTop: 4,
      }}>
        <span style={{ fontSize: 9, color: "#2e3d4d", letterSpacing: 1 }}>PROTOCOLS:</span>
        {PROTOCOLS.map(p => (
          <span key={p.id} style={{ fontSize: 9, display: "flex", alignItems: "center", gap: 5 }}>
            <span style={{
              display: "inline-block", width: 8, height: 8,
              borderRadius: 2, background: p.color,
            }} />
            <span style={{ color: p.color }}>{p.label}</span>
          </span>
        ))}
        <span style={{ marginLeft: "auto", fontSize: 9, color: "#2e3d4d" }}>
          Click cells to assign · Hover to highlight
        </span>
      </div>
    </div>
  );
}
