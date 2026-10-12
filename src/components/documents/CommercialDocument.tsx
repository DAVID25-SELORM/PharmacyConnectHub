import type { CSSProperties } from "react";
import type { BusinessDocumentModel } from "@/lib/business-document-model";
import { resolveDocumentBranding } from "@/lib/document-branding";
import { BusinessIdentityHeader } from "./BusinessDocument";

export function CommercialDocument({
  model,
  preview = false,
}: {
  model: BusinessDocumentModel;
  preview?: boolean;
}) {
  const branding = resolveDocumentBranding(model.issuer);
  return (
    <article
      className={`print-document commercial-document ${preview ? "document-a4-preview" : "hidden print:block"}`}
      style={{ "--document-accent": branding.accentColor } as CSSProperties}
    >
      <header className="commercial-document__header">
        <BusinessIdentityHeader
          business={
            model.issuer ? { ...model.issuer, branding: model.issuer.branding ?? {} } : null
          }
        />
        <div className="commercial-document__identity">
          <h1>{model.title}</h1>
          <strong>{model.reference}</strong>
        </div>
      </header>
      <section className="commercial-document__parties">
        {model.recipient && (
          <div>
            <h2>{model.recipient.label}</h2>
            <strong>{model.recipient.name}</strong>
            {model.recipient.lines?.map((line, i) => (
              <div key={i}>{line}</div>
            ))}
          </div>
        )}
        <dl>
          {model.metadata
            .filter(([, value]) => value)
            .map(([label, value]) => (
              <div key={label}>
                <dt>{label}</dt>
                <dd>{value}</dd>
              </div>
            ))}
        </dl>
      </section>
      <table>
        <thead>
          <tr>
            {model.columns.map((column, index) => (
              <th
                key={index}
                className={model.numericColumns?.includes(index) ? "document-number" : ""}
              >
                {column}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {model.rows.map((row, index) => (
            <tr key={index}>
              {row.map((cell, col) => (
                <td
                  key={col}
                  className={model.numericColumns?.includes(col) ? "document-number" : ""}
                >
                  {cell}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
      {model.summary?.length ? (
        <dl className="document-summary">
          {model.summary.map(([label, value]) => (
            <div key={label}>
              <dt>{label}</dt>
              <dd>{value}</dd>
            </div>
          ))}
        </dl>
      ) : null}
      {model.notes?.map((note, i) => (
        <p className="document-note" key={i}>
          {note}
        </p>
      ))}
      {branding.footer_note && <footer>{branding.footer_note}</footer>}
    </article>
  );
}
