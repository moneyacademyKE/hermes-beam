import React from 'react';
import FadeIn from './common/FadeIn';

interface ServiceItemProps {
  number: string;
  name: string;
  description: string;
  delay: number;
}

const ServiceItem: React.FC<ServiceItemProps> = ({ number, name, description, delay }) => {
  return (
    <FadeIn delay={delay} y={30} as="div" className="w-full">
      <div className="flex flex-col sm:flex-row items-start sm:items-center py-8 sm:py-10 md:py-12 gap-6
        border-b border-dark-text/15 last:border-b-0">
        <p className="flex-shrink-0 font-black text-dark-text text-left mr-0 sm:mr-8 md:mr-12"
          style={{ fontSize: 'clamp(3rem, 10vw, 140px)', lineHeight: 1 }}>
          {number}
        </p>
        <div className="flex-grow flex flex-col text-left">
          <h3 className="font-medium uppercase text-dark-text mb-2"
            style={{ fontSize: 'clamp(1rem, 2.2vw, 2.1rem)' }}>
            {name}
          </h3>
          <p className="font-light leading-relaxed max-w-2xl text-dark-text opacity-60"
            style={{ fontSize: 'clamp(0.85rem, 1.6vw, 1.25rem)' }}>
            {description}
          </p>
        </div>
      </div>
    </FadeIn>
  );
};

const ServicesSection: React.FC = () => {
  const services = [
    {
      number: '01',
      name: '3D Modeling',
      description: 'Creation of detailed objects, characters, or environments tailored to specific client needs, ideal for games, products, and visualizations.',
    },
    {
      number: '02',
      name: 'Rendering',
      description: 'High-quality, photorealistic renders that showcase designs with custom lighting, textures, and materials to bring concepts to life.',
    },
    {
      number: '03',
      name: 'Motion Design',
      description: 'Dynamic animations and motion graphics that add energy and storytelling to brands, products, and digital experiences.',
    },
    {
      number: '04',
      name: 'Branding',
      description: 'Crafting cohesive visual identities -- from logos to full brand systems -- that communicate a clear and memorable presence.',
    },
    {
      number: '05',
      name: 'Web Design',
      description: 'Designing clean, modern, and conversion-focused websites with attention to layout, typography, and user experience.',
    },
  ];

  return (
    <section id="services" className="bg-services-bg
      rounded-t-[40px] sm:rounded-t-[50px] md:rounded-t-[60px]
      px-5 sm:px-8 md:px-10 py-20 sm:py-24 md:py-32">
      <div className="container mx-auto max-w-5xl">
        <FadeIn delay={0} y={40} as="h2">
          <h2 className="text-dark-text font-black uppercase text-center mb-16 sm:mb-20 md:mb-28"
            style={{ fontSize: 'clamp(3rem, 12vw, 160px)' }}>
            Services
          </h2>
        </FadeIn>

        <div className="flex flex-col items-center">
          {services.map((service, index) => (
            <ServiceItem
              key={index}
              number={service.number}
              name={service.name}
              description={service.description}
              delay={0.1 * (index + 1)}
            />
          ))}
        </div>
      </div>
    </section>
  );
};

export default ServicesSection;