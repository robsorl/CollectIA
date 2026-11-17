import type { Metadata } from 'next';
import { Inter } from 'next/font/google';
import './globals.css';

const inter = Inter({ subsets: ['latin'], variable: '--font-inter' });

export const metadata: Metadata = {
  title: 'CollectIA — Numérisez ta collection, échange tes doublons',
  description:
    'Digitalise ta collection de cartes, classe-la par extension, gère tes doublons et trouve des collectionneurs avec qui échanger.',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="fr" className={inter.variable}>
      <body className="min-h-screen bg-background font-sans text-white antialiased">{children}</body>
    </html>
  );
}
