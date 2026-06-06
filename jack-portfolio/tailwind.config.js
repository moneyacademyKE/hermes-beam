/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  theme: {
    extend: {
      fontFamily: {
        kanit: ['Kanit', 'sans-serif'],
      },
      colors: {
        'dark-bg': '#0C0C0C',
        'light-text': '#D7E2EA',
        'services-bg': '#FFFFFF',
        'dark-text': '#0C0C0C',
      }
    },
  },
  plugins: [],
}