import React, { useRef, useEffect, useState } from 'react';
import { motion, useScroll, useTransform } from 'framer-motion';

const imageUrls = [
  "https://motionsites.ai/assets/hero-space-voyage-preview-eECLH3Yc.gif",
  "https://motionsites.ai/assets/hero-codenest-preview-Cgppc2qV.gif",
  "https://motionsites.ai/assets/hero-vex-ventures-preview-BczMFIiw.gif",
  "https://motionsites.ai/assets/hero-stellar-ai-v2-preview-DjvxjG3C.gif",
  "https://motionsites.ai/assets/hero-asme-preview-B_nGDnTP.gif",
  "https://motionsites.ai/assets/hero-transform-data-preview-Cx5OU29N.gif",
  "https://motionsites.ai/assets/hero-vitara-preview-Cjz2QYyU.gif",
  "https://motionsites.ai/assets/hero-terra-preview-BFjrCr7T.gif",
  "https://motionsites.ai/assets/hero-skyelite-preview-DHaZIgUv.gif",
  "https://motionsites.ai/assets/hero-aethera-preview-DknSlcTa.gif",
  "https://motionsites.ai/assets/hero-designpro-preview-D8c5_een.gif",
  "https://motionsites.ai/assets/hero-stellar-ai-preview-D3HL6bw1.gif",
  "https://motionsites.ai/assets/hero-xportfolio-preview-D4A8maiC.gif",
  "https://motionsites.ai/assets/hero-orbit-web3-preview-BXt4OttD.gif",
  "https://motionsites.ai/assets/hero-nexora-preview-cx5HmUgo.gif",
  "https://motionsites.ai/assets/hero-evr-ventures-preview-DZxeVFEX.gif",
  "https://motionsites.ai/assets/hero-planet-orbit-preview-DWAP8Z1P.gif",
  "https://motionsites.ai/assets/hero-new-era-preview-CocuDUm9.gif",
  "https://motionsites.ai/assets/hero-wealth-preview-B70idl_u.gif",
  "https://motionsites.ai/assets/hero-luminex-preview-CxOP7ce6.gif",
  "https://motionsites.ai/assets/hero-celestia-preview-0yO3jXO8.gif",
];

const Row: React.FC<{ images: string[]; direction: 'left' | 'right' }> = ({ images, direction }) => {
  const rowRef = useRef<HTMLDivElement>(null);
  const { scrollYProgress } = useScroll();

  const [containerWidth, setContainerWidth] = useState(0);

  // Measure container width on mount and resize
  useEffect(() => {
    const handleResize = () => {
      if (rowRef.current) {
        setContainerWidth(rowRef.current.scrollWidth / 3); // Total width of one set of images
      }
    };
    handleResize(); // Initial measurement
    window.addEventListener('resize', handleResize);
    return () => window.removeEventListener('resize', handleResize);
  }, []);

  const x = useTransform(
    scrollYProgress,
    [0, 1],
    direction === 'left' ? [0, -containerWidth] : [0, containerWidth]
  );

  return (
    <motion.div
      ref={rowRef}
      className={`flex flex-nowrap gap-3 mb-3 md:mb-5 lg:mb-8`}
      style={{ x, willChange: 'transform' }}
    >
      {[...images, ...images, ...images].map((src, index) => (
        <div key={index} className="flex-shrink-0 w-[420px] h-[270px]">
          <img
            src={src}
            alt={`Marquee item ${index}`}
            className="w-full h-full object-cover rounded-2xl"
            loading="lazy"
          />
        </div>
      ))}
    </motion.div>
  );
};

const MarqueeSection: React.FC = () => {
  const row1Images = imageUrls.slice(0, 11);
  const row2Images = imageUrls.slice(11);

  return (
    <section className="bg-dark-bg pt-24 sm:pt-32 md:pt-40 pb-10 overflow-hidden">
      {/* Container for rows to ensure consistent sizing and centering for overflow content */}
      <div className="flex flex-col">
        <Row images={row1Images} direction="right" />
        <Row images={row2Images} direction="left" />
      </div>
    </section>
  );
};

export default MarqueeSection;