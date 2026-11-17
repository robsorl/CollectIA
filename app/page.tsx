export default function Home() {
  return (
    <main className="mx-auto flex max-w-4xl flex-col items-center justify-center gap-8 px-6 py-24 text-center">
      <h1 className="text-4xl font-bold tracking-tight text-primary sm:text-5xl">CollectIA</h1>
      <p className="text-xl text-gray-300">
        Numérisez ta collection de cartes. Trouve des échanges pour tes doublons.
      </p>
      <div className="flex gap-4">
        <a
          href="#"
          className="rounded-lg bg-primary px-6 py-3 font-semibold text-background transition hover:opacity-90"
        >
          Commencer — gratuit
        </a>
        <a
          href="#"
          className="rounded-lg border border-gray-600 px-6 py-3 font-semibold text-white transition hover:border-primary"
        >
          Se connecter
        </a>
      </div>
      <div className="grid gap-6 pt-12 sm:grid-cols-3">
        <Feature title="Numérise" body="Recherche, ajout rapide et scan du numéro de carte." />
        <Feature
          title="Classe"
          body="Par extension, série et thématiques personnalisées, avec suivi des doublons."
        />
        <Feature
          title="Échange"
          body="Matching automatique : tes doublons contre ce que tu cherches."
        />
      </div>
    </main>
  );
}

function Feature({ title, body }: { title: string; body: string }) {
  return (
    <div className="rounded-xl border border-gray-800 bg-surface p-6 text-left">
      <h2 className="mb-2 font-semibold text-primary">{title}</h2>
      <p className="text-sm text-gray-400">{body}</p>
    </div>
  );
}
