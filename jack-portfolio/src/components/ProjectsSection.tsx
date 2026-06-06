import React, { useRef } from 'react';
import { motion, useScroll, useTransform, MotionValue } from 'framer-motion';
import FadeIn from './common/FadeIn';
import LiveProjectButton from './common/LiveProjectButton';

interface ProjectImage {
  src: string;
  alt: string;
}

interface ProjectData {
  number: string;
  category: string;
  name: string;
  link: string; // Placeholder for live project link
  images: {
    col1_img1: ProjectImage;
    col1_img2: ProjectImage;
    col2_img: ProjectImage;
  };
}

const projects: ProjectData[] = [
  {
    number: '01',
    category: 'Client',
    name: 'Nextlevel Studio',
    link: '#',
    images: {
      col1_img1: { src: "https://images.higgs.ai/?default=1&output=webp&url=https%3A%2F%2Fd8j0ntlcm91z4.cloudfront.net%2Fuser_38xzZboKViGWJOttwIXH07lWA1P%2Fhf_20260412_055344_5eff02e0-87a5-41ce-b64f-eb08da8f33db.png&w=1280&q=85", alt: "Nextlevel Studio Image 1" },
      col1_img2: { src: "https://images.higgs.ai/?default=1&output=webp&url=https%3A%2F%2Fd8j0ntlcm91z4.cloudfront.net%2Fuser_38xzZboKViGWJOttwIXH07lWA1P%2Fhf_20260412_055431_11d841fd-8b41-46a5-82e4-b04f2407a7d8.png&w=1280&q=85", alt: "Nextlevel Studio Image 2" },
      col2_img: { src: "https://images.higgs.ai/?default=1&output=webp&url=https%3A%2F%2Fd8j0ntlcm91z4.cloudfront.net%2Fuser_38xzZboKViGWJOttwIXH07lWA1P%2Fhf_20260412_055451_e317bf2d-28d4-48cc-86b0-6f72f25b6327.png&w=1280&q=85", alt: "Nextlevel Studio Image 3" },
    },
  },
  {
    number: '02',
    category: 'Personal',
    name: 'Aura Brand Identity',
    link: '#',
    images: {
      col1_img1: { src: "https://images.higgs.ai/?default=1&output=webp&url=https%3A%2F%2Fd8j0ntlcm91z4.cloudfront.net%2Fuser_38xzZboKViGWJOttwIXH07lWA1P%2Fhf_20260412_055654_911201c5-36d9-4bc6-bac7-331adfce159f.png&w=1280&q=85", alt: "Aura Brand Identity Image 1" },
      col1_img2: { src: "https://images.higgs.ai/?default=1&output=webp&url=https%3A%2F%2Fd8j0ntlcm91z4.cloudfront.net%2Fuser_38xzZboKViGWJOttwIXH07lWA1P%2Fhf_20260412_055723_5ceda0b8-d9c2-4665-b2e3-83ba19ba76d1.png&w=1280&q=85", alt: "Aura Brand Identity Image 2" },
      col2_img: { src: "https://images.higgs.ai/?default=1&output=webp&url=https%3A%2F%2Fd8j0ntlcm91z4.cloudfront.net%2Fuser_38xzZboKViGWJOttwIXH07lWA1P%2Fhf_20260412_055753_adc5dcbd-a8e6-49c0-b43a-9b030d835cea.png&w=1280&q=85", alt: "Aura Brand Identity Image 3" },
    },
  },
  {
    number: '03',
    category: 'Client',
    name: 'Solaris Digital',
    link: '#',
    images: {
      col1_img1: { src: "https://images.higgs.ai/?default=1&output=webp&url=https%3A%2F%2Fd8j0ntlcm91z4.cloudfront.net%2Fuser_38xzZboKViGWJOttwIXH07lWA1P%2Fhf_20260412_055759_963cfb0b-4bd1-4b0f-9d0a-09bd6cf95b2f.png&w=1280&q=85", alt: "Solaris Digital Image 1" },
      col1_img2: { src: "https://images.higgs.ai/?default=1&output=webp&url=https%3A%2F%2Fd8j0ntlcm91z4.cloudfront.net%2Fuser_38xzZboKViGWJOttwIXH07lWA1P%2Fhf_20260412_060108_438f781a-9846-4dcc-89ab-c4e6cb830f5b.png&w=1280&q=85", alt: "Solaris Digital Image 2" },
      col2_img: { src: "https://images.higgs.ai/?default=1&output=webp&url=https%3A%2F%2Fd8j0ntlcm91z4.cloudfront.net%2Fuser_38xzZboKViGWJOttwIXH07lWA1P%2Fhf_20260412_055818_9d062121-ad7e-46b9-999a-1a6a692ef1ee.png&w=1280&q=85", alt: "Solaris Digital Image 3" },
    },
  },
];

interface ProjectCardProps {
  project: ProjectData;
  index: number;
  totalCards: number;
  scrollYProgress: MotionValue<number>;
}

const ProjectCard: React.FC<ProjectCardProps> = ({ project, index, totalCards, scrollYProgress }) => {
  const ref = useRef<HTMLDivElement>(null);

  // Calculate target scale for the sticky effect
  const targetScale = 1 - (totalCards - 1 - index) * 0.03;

  const scale = useTransform(scrollYProgress, [0, 1], [1, targetScale]);
  
  // Calculate depth offset for sticky positioning
  const topOffset = index * 28; // Adjust based on desired vertical spacing when stacked

  return (
    <motion.div
      ref={ref}
      style={{
        scale,
        top: `${topOffset}px`,
        zIndex: totalCards - index, // Ensure correct stacking order
      }}
      className={`
        sticky top-24 md:top-32 h-[85vh]
        bg-dark-bg border-2 border-light-text text-light-text
        rounded-[40px] sm:rounded-[50px] md:rounded-[60px]
        p-4 sm:p-6 md:p-8
        flex flex-col will-change-transform
      `}
    >
      {/* Card Header */}
      <div className="flex flex-col sm:flex-row sm:justify-between sm:items-center mb-6 md:mb-8 gap-4 sm:gap-0">
        <div className="flex items-baseline gap-4 sm:gap-6">
          <p className="font-black" style={{ fontSize: 'clamp(3rem, 10vw, 140px)', lineHeight: 1 }}>
            {project.number}
          </p>
          <div className="flex flex-col self-end">
            <span className="font-medium uppercase text-sm md:text-base tracking-wider opacity-70">
              {project.category}
            </span>
            <h3 className="font-bold uppercase text-lg md:text-xl lg:text-3xl tracking-wide leading-tight">
   
           {project.name}
            </h3>
          </div>
        </div>
        <a href={project.link} target="_blank" rel="noopener noreferrer">
          <LiveProjectButton />
        </a>
      </div>

      {/* Image Grid */}
      <div className="flex flex-grow gap-4 sm:gap-6 md:gap-8 overflow-hidden">
        {/* Column 1 */}
        <div className="flex flex-col w-[40%] gap-4 sm:gap-6 md:gap-8">
          <img
            src={project.images.col1_img1.src}
            alt={project.images.col1_img1.alt}
            className="w-full object-cover rounded-[40px] sm:rounded-[50px] md:rounded-[60px]"
            style={{ height: 'clamp(130px, 16vw, 230px)' }}
            loading="lazy"
          />
          <img
            src={project.images.col1_img2.src}
            alt={project.images.col1_img2.alt}
            className="w-full flex-grow object-cover rounded-[40px] sm:rounded-[50px] md:rounded-[60px]"
            style={{ height: 'clamp(160px, 22vw, 340px)' }}
            loading="lazy"
          />
        </div>
        {/* Column 2 */}
        <div className="w-[60%]">
          <img
            src={project.images.col2_img.src}
            alt={project.images.col2_img.alt}
            className="w-full h-full object-cover rounded-[40px] sm:rounded-[50px] md:rounded-[60px]"
            loading="lazy"
          />
        </div>
      </div>
    </motion.div>
  );
};


const ProjectsSection: React.FC = () => {
  const containerRef = useRef<HTMLDivElement>(null);
  const { scrollYProgress } = useScroll({
    target: containerRef,
    offset: ['start start', 'end end'],
  });

  return (
    <section id="projects" className="bg-dark-bg text-light-text relative
      rounded-t-[40px] sm:rounded-t-[50px] md:rounded-t-[60px]
      -mt-10 sm:-mt-12 md:-mt-14 z-10
      px-5 sm:px-8 md:px-10 py-20 sm:py-24 md:py-32">
      <div className="container mx-auto max-w-7xl">
        <FadeIn delay={0} y={40} as="h2">
          <h2 className="hero-heading font-black uppercase text-center mb-16 sm:mb-20 md:mb-28"
            style={{ fontSize: 'clamp(3rem, 12vw, 160px)' }}>
            Projects
          </h2>
        </FadeIn>

        <div ref={containerRef} className="relative pt-10" style={{ height: `calc(100vh * ${projects.length})` }}> {/* Increased height for full scroll range */}
          {projects.map((project, index) => (
            <ProjectCard
              key={project.name}
              project={project}
              index={index}
              totalCards={projects.length}
              scrollYProgress={scrollYProgress}
            />
          ))}
        </div>
      </div>
    </section>
  );
};

export default ProjectsSection;