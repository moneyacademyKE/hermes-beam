import React from 'react';
import ContactButton from './common/ContactButton';
import Magnet from './common/Magnet';
import FadeIn from './common/FadeIn';

const HeroSection: React.FC = () => {
  const navLinks = [
    { name: 'About', href: '#about' },
    { name: 'Price', href: '#price' },
    { name: 'Projects', href: '#projects' },
    { name: 'Contact', href: '#contact' },
  ];

  return (
    <section className="relative h-screen flex flex-col bg-dark-bg text-light-text overflow-x-clip">
      {/* Navbar */}
      <FadeIn delay={0} y={-20} as="nav">
        <div className="container mx-auto px-6 md:px-10 pt-6 md:pt-8">
          <ul className="flex justify-between">
            {navLinks.map((link) => (
              <li key={link.name}>
                <a
                  href={link.href}
                  className="text-sm md:text-lg lg:text-[1.4rem] font-medium uppercase tracking-wider transition-opacity duration-200 hover:opacity-70"
                >
                  {link.name}
                </a>
              </li>
            ))}
          </ul>
        </div>
      </FadeIn>

      {/* Hero Heading */}
      <div className="relative z-10 flex-grow flex items-center justify-center overflow-hidden">
        <FadeIn delay={0.15} y={40} className="w-full">
          <h1 className="hero-heading font-black uppercase tracking-tight leading-none whitespace-nowrap w-full
             text-[14vw] sm:text-[15vw] md:text-[16vw] lg:text-[17.5vw]
             text-center mt-6 sm:mt-4 md:-mt-5 xl:-mt-10">
            Hi, i&apos;m jack
          </h1>
        </FadeIn>
      </div>

      {/* Hero Portrait - Absolute positioning */}
      <Magnet padding={150} strength={3} activeTransition="transform 0.3s ease-out" inactiveTransition="transform 0.6s ease-in-out">
        <FadeIn delay={0.6} y={30} className="absolute left-1/2 -translate-x-1/2 z-10
          w-[280px] sm:w-[360px] md:w-[440px] lg:w-[520px]
          top-1/2 -translate-y-1/2 sm:top-auto sm:translate-y-0 sm:bottom-0">
          <img
            src="https://shrug-person-78902957.figma.site/_components/v2/d24c01ad3a56fc65e942a1f501eb73db42d7cf9a/Rectangle_40443.81459862.png"
            alt="Jack's Portrait"
            className="w-full h-auto object-cover"
            loading="eager"
            fetchPriority="high"
          />
        </FadeIn>
      </Magnet>


      {/* Bottom Bar */}
      <div className="absolute bottom-0 left-0 right-0 z-20 container mx-auto px-6 md:px-10 pb-7 sm:pb-8 md:pb-10 flex justify-between items-end">
        <FadeIn delay={0.35} y={20} as="p">
          <p className="font-light uppercase tracking-wide leading-snug
            max-w-[160px] sm:max-w-[220px] md:max-w-[260px]"
            style={{ fontSize: 'clamp(0.75rem, 1.4vw, 1.5rem)' }}>
            a 3d creator driven by crafting striking and unforgettable projects
          </p>
        </FadeIn>
        <FadeIn delay={0.5} y={20}>
          <ContactButton />
        </FadeIn>
      </div>
    </section>
  );
};

export default HeroSection;