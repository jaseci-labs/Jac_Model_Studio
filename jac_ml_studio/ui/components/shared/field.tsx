import type { ReactNode } from "react";

export function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="flex flex-col gap-1">
      <span className="micro-label">{label}</span>
      {children}
    </div>
  );
}

export function TextInput({
  value,
  onChange,
  placeholder,
  mono,
}: {
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  mono?: boolean;
}) {
  return (
    <input
      type="text"
      value={value}
      onChange={(e) => onChange(e.target.value)}
      placeholder={placeholder}
      className={`w-full rounded-md border border-neutral-700 bg-[#121212] px-2 py-1 text-sm text-neutral-100 outline-none placeholder:text-neutral-600 focus:border-neutral-500 ${
        mono ? "font-mono" : ""
      }`}
    />
  );
}

export function Segmented({
  options,
  value,
  onChange,
}: {
  options: string[];
  value: string;
  onChange: (v: string) => void;
}) {
  return (
    <div className="flex gap-1">
      {options.map((opt) => (
        <button
          key={opt}
          onClick={() => onChange(opt)}
          className={`rounded-md border px-3 py-1 text-xs transition-colors ${
            value === opt
              ? "border-neutral-500 bg-[#1a1a1a] text-neutral-100"
              : "border-neutral-700 text-neutral-500 hover:text-neutral-300"
          }`}
        >
          {opt}
        </button>
      ))}
    </div>
  );
}
