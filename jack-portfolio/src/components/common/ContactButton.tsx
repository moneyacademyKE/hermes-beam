import React from 'react';
import { motion } from 'framer-motion';

interface ContactButtonProps {
  className?: string;
  onClick?: () => void;
}

const ContactButton: React.FC<ContactButtonProps> = ({ className, onClick }) => {
  return (
    <motion.button
      className={`
        relative overflow-hidden
        rounded-full p-[2px]
        before:absolute before:inset-0
        before:bg-gradient-to-r before:from-[#18011F] before:via-[#B600A8] before:to-[#BE4C00]
        before:opacity-0 before:transition-opacity before:duration-300 hover:before:opacity-100
        z-0
        ${className}
      `}
      onClick={onClick}
      whileHover={{ scale: 1.05 }}
      whileTap={{ scale: 0.95 }}
      transition={{ type: "spring", stiffness: 400, damping: 17 }}
    >
      <span
        className={`
          relative z-10 block
          bg-dark-bg rounded-full
          px-8 py-3 sm:px-10 sm:py-3.5 md:px-12 md:py-4
          text-xs sm:text-sm md:text-base font-medium uppercase tracking-widest text-light-text
          transition-colors duration-300
        `}
        style={{
          boxShadow: 'inset 0px 4px 4px rgba(181, 1, 167, 0.25), inset 4px 4px 12px #7721B1',
          outline: '2px solid white', // White outline
          outlineOffset: '-3px' // Offset the outline inwards
        }}
      >
        Contact Me
      </span>
    </motion.button>
  );
};

export default ContactButton;