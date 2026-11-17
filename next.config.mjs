/** @type {import('next').NextConfig} */
const nextConfig = {
  images: {
    remotePatterns: [
      { protocol: 'https', hostname: 'images.pokemontcg.io' },
      { protocol: 'https', hostname: 'assets.pokemontcg.io' },
      { protocol: 'https', hostname: 'cdn.tcgdex.net' },
    ],
  },
};

export default nextConfig;
